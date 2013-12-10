;;; written by David Lichteblau, based on code by Christophe Rhodes,
;;; Closette, and SBCL
;;;
;;; http://www.lichteblau.com/git/?p=specializable.git;a=blob_plain;f=specializable.lisp;hb=eb30d235951c3c1d128811278760f1db36cd336c

(defpackage "SPECIALIZABLE"
  (:use "CL" "SB-EXT")
  (:export "SPECIALIZABLE-GENERIC-FUNCTION" "SPECIALIZABLE-METHOD"
           "EXTENDED-SPECIALIZER"

           "SPECIALIZER-ACCEPTS-P" "SPECIALIZER-ACCEPTS-CLASS-P"
           "SPECIALIZER<"

           "GENERALIZER-OF-USING-CLASS"
           "COMPUTE-APPLICABLE-METHODS-USING-GENERALIZERS"
           
           "DEFINE-EXTENDED-SPECIALIZER"))

(in-package "SPECIALIZABLE")

(defclass extended-specializer (sb-mop:specializer)
  ((direct-methods :initform nil
                   :accessor %specializer-direct-methods
                   :reader specializer-direct-methods)))

(defclass specializable-generic-function (standard-generic-function)
  ((extended-specializers :initform (make-hash-table :test 'equal)
                          :reader generic-function-extended-specializers)
   (emf-table :initform (make-hash-table :test 'equal) :reader emf-table))
  (:metaclass sb-mop:funcallable-standard-class)
  (:default-initargs :method-class (find-class 'specializable-method)))

(defclass specializable-method (standard-method)
  ((lambda-expression :initarg :lambda-expression
		      :accessor specializable-method-lambda-expression)))

(defmacro define-extended-specializer (name (gf-var &rest args) &body body)
  ;; FIXME: unparser
  `(setf (get ',name 'extended-specializer-parser)
	 (lambda (,gf-var ,@args)
	   ,@body)))

;; doesn't work, because we'd have to dump GF into the fasl for the macro
;; expansion
;;; (defun intern-extended-specializer (gf sname)
;;;   (destructuring-bind (kind &rest args) sname
;;;     (setf (gethash sname (generic-function-extended-specializers gf))
;;; 	  (apply (or (get kind 'extended-specializer-parser)
;;; 		     (error "not declared as an extended specializer name: ~A"
;;; 			    kind))
;;; 		 gf
;;; 		 args))))

(defun make-extended-specializer (sname)
  (destructuring-bind (kind &rest args) sname
    (apply (or (get kind 'extended-specializer-parser)
	       (error "not declared as an extended specializer name: ~A"
		      kind))
	   '|This is not a generic function| ;fixme, see comment above
	   args)))

(defmethod sb-mop:add-direct-method ((specializer extended-specializer) method)
  (pushnew method (%specializer-direct-methods specializer)))

(defmethod sb-mop:remove-direct-method ((specializer extended-specializer) method)
  (setf (%specializer-direct-methods specializer)
        (remove method (specializer-direct-methods specializer))))

;;; from SBCL:

(defmethod sb-pcl:parse-specializer-using-class
    ((gf specializable-generic-function) name)
  (cond
    ((typep name 'sb-mop:specializer) name)
    ((symbolp name) (find-class name))
    ((consp name)
     (case (car name)
       (eql (sb-mop:intern-eql-specializer (cadr name)))
       (t (make-extended-specializer name))))
    (t (error "unexpected specializer name"))))

(defmethod sb-pcl:make-method-specializers-form
    ((gf specializable-generic-function) method snames env)
  (declare (ignore method env))
  (flet ((parse (name)
           (cond
             ((typep name 'sb-mop:specializer) name)
             ((symbolp name) `(find-class ',name))
             ((consp name)
	      (case (car name)
		(eql `(sb-mop:intern-eql-specializer ,(cadr name)))
		(t `(make-extended-specializer ',name))))
             (t (error "unexpected specializer name")))))
    `(list ,@(mapcar #'parse snames))))

;;; from Closette, changed to use some SBCL functions:

;;; FIXME: this is not actually sufficient argument checking
(defun required-portion (gf args)
  (let ((number-required
	 (sb-pcl::arg-info-number-required (sb-pcl::gf-arg-info gf))))
    (when (< (length args) number-required)
      (error "Too few arguments to generic function ~S." gf))
    (subseq args 0 number-required)))

;;; FIXME: in some kind of order, the discriminating function needs to handle:
;;; - argument count checking;
;;; - keyword argument validity;
;;; - flushing the emf cache on method addition/removal
;;; - flushing the cache on class redefinition;
;;; - cache thread-safety.
(defmethod sb-mop:compute-discriminating-function ((gf specializable-generic-function))
  (lambda (&rest args)
    (let* ((generalizers (mapcar (lambda (x) (generalizer-of-using-class gf x))
                                 (required-portion gf args)))
	   (emfun (gethash generalizers (emf-table gf) nil)))
      (if emfun
	  (funcall emfun args)
	  (slow-method-lookup gf args generalizers)))))

(defun slow-method-lookup (gf args generalizers)
  ;; differs from closette
  (multiple-value-bind (applicable-methods definitivep)
      (compute-applicable-methods-using-generalizers gf generalizers)
    (if definitivep
	(let* ((emfun
		(compute-effective-method-function gf applicable-methods)))
	  (setf (gethash generalizers (emf-table gf)) emfun)
	  (funcall emfun args))
	(funcall (compute-effective-method-function
                  gf (sb-mop:compute-applicable-methods gf args))
                 args))))

;; new, not in closette
(defgeneric generalizer-of-using-class (generic-function object))
(defmethod generalizer-of-using-class ((generic-function specializable-generic-function) object)
  (class-of object))

(defgeneric specializer-accepts-generalizer-p (specializer generalizer))
(defmethod specializer-accepts-generalizer-p ((specializer class) (generalizer class))
  ;; does the specializer's object have the -same- class as the the actual
  ;; argument?
  (if (subtypep generalizer specializer)
      ;; definitive: this method matches all instances of this class
      (values t t)
      ;; definitive: this method doesn't match instances of this class
      (values nil t)))
(defmethod specializer-accepts-generalizer-p
    ((specializer sb-mop:eql-specializer) (generalizer class))
  ;; does the specializer's object have the -same- class as the actual
  ;; argument?
  (if (eq generalizer (class-of (sb-mop:eql-specializer-object specializer)))
      ;; not definitive, since the actual object might differ
      (values t nil)
      ;; definitely not the same object
      (values nil t)))

(defgeneric compute-applicable-methods-using-generalizers (gf generalizers))
(defmethod compute-applicable-methods-using-generalizers
    ((gf specializable-generic-function) generalizers)
  ;; differs from closette
  (let ((result-definitive-p t))
    (flet ((filter (method)
             (every (lambda (s g)
                      (multiple-value-bind (acceptsp definitivep)
                          (specializer-accepts-generalizer-p s g)
                        (unless definitivep
                          (setf result-definitive-p nil))
                        acceptsp))
                    (sb-mop:method-specializers method) generalizers))
           (sorter (m1 m2)
             (method-more-specific-p gf m1 m2 generalizers)))
      (values
       (sort
        (copy-list (remove-if-not #'filter (sb-mop:generic-function-methods gf)))
        #'sorter)
       result-definitive-p))))

;; new, not in closette
(defgeneric specializer-accepts-p (specializer object))
(defmethod specializer-accepts-p ((specializer class) object)
  (typep object specializer))
(defmethod specializer-accepts-p ((specializer sb-mop:eql-specializer) object)
  (eq object (sb-mop:eql-specializer-object specializer)))

(defmethod compute-applicable-methods
    ((gf specializable-generic-function) arguments)
  ;; new, not in closette
  (sort
   (copy-list
    (remove-if-not #'(lambda (method)
		       (every #'specializer-accepts-p
			      (sb-mop:method-specializers method)
			      arguments))
		   (sb-mop:generic-function-methods gf)))
   (let ((generalizers (mapcar (lambda (x) (generalizer-of-using-class gf x))
                               (required-portion gf arguments))))
     (lambda (m1 m2)
       (method-more-specific-p gf m1 m2 generalizers)))))

(defun method-more-specific-p (gf method1 method2 generalizers)
  ;; differs from closette
  (declare (ignore gf))
  ;; FIXME: argument precedence order
  (block nil
    (mapc #'(lambda (spec1 spec2 generalizer)
	      (ecase (specializer< spec1 spec2 generalizer)
		(< (return t))
		(=)
		((nil > /=) (return nil))))
	  (sb-mop:method-specializers method1)
	  (sb-mop:method-specializers method2)
	  generalizers)
    nil))

;; new, not in closette
(defgeneric specializer< (s1 s2 generalizer))
(defmethod specializer< ((s1 class) (s2 class) (generalizer class))
  (if (eq s1 s2)
      '=
      (let ((cpl (sb-mop:class-precedence-list generalizer)))
	(if (find s2 (cdr (member s1 cpl)))
	    '<
	    nil))))
(defmethod specializer<
    ((s1 sb-mop:eql-specializer) (s2 sb-mop:eql-specializer) generalizer)
  (declare (ignore generalizer))
  (if (eq (sb-mop:eql-specializer-object s1) (sb-mop:eql-specializer-object s2))
      '=
      nil))
(defmethod specializer< ((s1 sb-mop:eql-specializer) (s2 class) generalizer)
  (declare (ignore generalizer))
  '<)
(defmethod specializer< ((c1 class) (c2 sb-mop:eql-specializer) generalizer)
  (declare (ignore generalizer))
  '>)

;;;; method combination

;;; FIXME: this is actually only standard method combination.

;; unchanged from closette
(defun primary-method-p (method)
  (null (method-qualifiers method)))
(defun before-method-p (method)
  (equal '(:before) (method-qualifiers method)))
(defun after-method-p (method)
  (equal '(:after) (method-qualifiers method)))
(defun around-method-p (method)
  (equal '(:around) (method-qualifiers method)))

;;; (defun compute-effective-method-function (gf methods)
;;;   (let ((primaries (remove-if-not #'primary-method-p methods))
;;;         (around (find-if #'around-method-p methods)))
;;;     (when (null primaries)
;;;       (error "No primary methods for the~@
;;;              generic function ~S." gf))
;;;     (if around
;;;         (let ((next-emfun
;;; 	       (compute-effective-method-function gf (remove around methods))))
;;;           #'(lambda (args)
;;;               (funcall (method-function around) args next-emfun)))
;;;         (let ((next-emfun (compute-primary-emfun (cdr primaries)))
;;; 	      (befores (remove-if-not #'before-method-p methods))
;;; 	      (reverse-afters
;;; 	       (reverse (remove-if-not #'after-method-p methods))))
;;;           #'(lambda (args)
;;;               (dolist (before befores)
;;;                 (funcall (method-function before) args nil))
;;;               (multiple-value-prog1
;;; 		  (funcall (method-function (car primaries)) args next-emfun)
;;;                 (dolist (after reverse-afters)
;;;                   (funcall (method-function after) args nil))))))))

(defun compute-effective-method-function (gf methods)
  (let* ((primaries
	  (or (remove-if-not #'primary-method-p methods)
	      (error "No primary methods for the generic function ~S." gf)))
	 (primary-emf
	  (let* ((nexts (mapcar #'sb-mop:method-function (cdr primaries)))
		 (befores (remove-if-not #'before-method-p methods))
		 (reverse-afters
		  (reverse (remove-if-not #'after-method-p methods))))
	    #'(lambda (args)
		(dolist (before befores)
		  (funcall (sb-mop:method-function before) args nil))
		(multiple-value-prog1
		    (funcall (sb-mop:method-function (car primaries))
			     args
			     nexts)
		  (dolist (after reverse-afters)
		    (funcall (sb-mop:method-function after) args nil))))))
	 (arounds (remove-if-not #'around-method-p methods)))
    (if arounds
        (let ((next (append (mapcar #'sb-mop:method-function (cdr arounds))
			    (lambda (args nexts)
			      (declare (ignore nexts))
			      (funcall primary-emf args)))))
	  (lambda (args)
	    (funcall (sb-mop:method-function (car arounds))
		     args
		     next)))
        primary-emf)))

;;;; example
(defclass cons-specializer (extended-specializer)
  ((car :initarg :car :reader %car)))
(defclass cons-generic-function (specializable-generic-function)
  ()
  (:metaclass sb-mop:funcallable-standard-class))

(define-extended-specializer cons (gf car)
  (make-instance 'cons-specializer :car car))

(defmethod sb-pcl:unparse-specializer-using-class
    ((gf cons-generic-function) (specializer cons-specializer))
  `(cons ,(%car specializer)))
(defmethod sb-pcl::same-specializer-p
    ((s1 cons-specializer) (s2 cons-specializer))
  (eql (%car s1) (%car s2)))

(defmethod generalizer-of-using-class ((gf cons-generic-function) arg)
  (typecase arg
    ((cons symbol) (car arg))
    (t (call-next-method))))
;;; FIXME: it looks like these protocol functions should have the GF
;;; as an argument, since generalizer-of-using-class does
(defmethod specializer-accepts-generalizer-p ((specializer cons-specializer) thing)
  (if (eql (%car specializer) thing)
      (values t t)
      (values nil t)))
;;; FIXME: yes, definitely need the gf!  
(defmethod specializer-accepts-generalizer-p (specializer (thing symbol))
  (specializer-accepts-generalizer-p specializer (find-class 'cons)))

(defmethod specializer-accepts-p ((specializer cons-specializer) obj)
  (and (consp obj)
       (eql (car obj) (%car specializer))))
(defmethod specializer< ((s1 cons-specializer) (s2 cons-specializer) generalizer)
  (declare (ignore generalizer))
  (if (eql (%car s1) (%car s2))
      '=
      nil))
(defmethod specializer< ((s1 cons-specializer) (s2 class) generalizer)
  (declare (ignore generalizer))
  '<)
(defmethod specializer< ((s1 cons-specializer) (s2 sb-mop:eql-specializer) generalizer)
  (declare (ignore generalizer))
  '>)
(defmethod specializer< ((s1 sb-mop:specializer) (s2 cons-specializer) generalizer)
  (ecase (specializer< s2 s1 generalizer)
    ((<) '>)
    ((>) '<)))

(defgeneric walk (form)
  (:generic-function-class cons-generic-function))

(defmethod walk ((form symbol))
  `(lookup ,form))
(defmethod walk ((form cons))
  `(call (flookup ,(car form)) (list ,@(mapcar #'walk (cdr form)))))
(defmethod walk ((form (cons quote)))
  (cadr form))
(defmethod walk ((form (cons let)))
  (let ((bindings (cadr form)))
    `(with-bindings ,bindings ,@(cddr form))))
