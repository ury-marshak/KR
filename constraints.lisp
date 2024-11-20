;;; -*- Mode: LISP; Package: KR; Base: 10; Syntax: Common-Lisp -*-


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;         The Garnet User Interface Development Environment.      ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; This code was written as part of the Garnet project at          ;;;
;;; Carnegie Mellon University, and has been placed in the public   ;;;
;;; domain.  If you are using this code or any part of Garnet,      ;;;
;;; please contact garnet@cs.cmu.edu to be put on the mailing list. ;;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;



(in-package "KR")


(eval-when (:execute :compile-toplevel :load-toplevel)
  (proclaim '(special common-lisp-user::*default-garnet-proclaim*))
  (if (boundp 'common-lisp-user::*default-garnet-proclaim*)
      (if common-lisp-user::*default-garnet-proclaim*
        (proclaim common-lisp-user::*default-garnet-proclaim*))
      (proclaim '(optimize (safety 0) (space 0)
		  (speed #-LUCID 3 #+LUCID 2) #+ALLEGRO (debug 0)))))



(defvar *setup-dependencies* T
  "If T (the default), dependencies are set up whenever GV and GVL are
   evaluated inside formulas.  If nil, no dependencies are set up.")



;;; --------------------------------------------------

;;; Fixed-path code.


(defun fixed-path-accessor (schema slots path-number)
  (let* ((current (a-formula-path *current-formula*))
	 (length (length current)))
    (or (and (< path-number length)
	     (elt current path-number))
	(progn
	  (dolist (slot slots)
	    (setf schema (g-value schema slot))
	    (if (listp schema)
		;; This handles relation slots, which are ALWAYS stored as
		;; a list.
		(setf schema (first schema))))
	  (unless (> length path-number)
	    ;; create more storage
	    (setf current
		  (setf (a-formula-path *current-formula*)
			(append current
				(make-list (- path-number length -1))))))
	  (setf (elt current path-number) schema)
	  schema))))



(defmacro kr-path (path-number &rest slots)
  `(fixed-path-accessor *schema-self* ',slots ,path-number))



;;; -------------------------------------------------- FORMULAS


;;; Reuses one of the destroyed formulas, or allocates one if none exist.
;;;
(defun make-new-formula ()
  (let ((l (1- (length *reuse-formulas*)))
	f)
    (if (< l 0)
	;; No formulas to reuse
	(setf f (make-a-formula))
	;; Reuse the last formula in the array.
	(progn
	  (setf f (aref *reuse-formulas* l))
	  (setf (a-formula-depends-on f) nil)
	  (setf (a-formula-cached-value f) nil)
	  (setf (a-formula-path f) nil)
	  (setf (a-formula-is-a f) nil)
	  (setf (a-formula-function f) nil)
	  (setf (a-formula-lambda f) nil)
	  (setf (a-formula-is-a-inv f) nil)
	  (decf (fill-pointer *reuse-formulas*))))
    (set-formula-number f 0)
    f))



(defun formula-fn (form &optional (initial-value nil) meta)
  "Creates an interpreted formula.  The <form> can be either a Lisp expression
  (which is used as the body of the formula), or another formula.  In the
  latter case, the other formula is made the parent, and this function
  creates an inherited formula.  The <initial-value>, which defaults to nil,
  is used as the initial cached value before the formula is evaluated."
  (locally (declare (optimize (speed 3) (space 0) #+(or ALLEGRO CCL) (debug 0)))
    (let ((formula (make-new-formula)))
    (setf (schema-name formula) (incf *schema-counter*))
    (setf (cached-value formula) initial-value)
    (setf (a-formula-meta formula) meta)
    (if (formula-p form)
      ;; We were passed an object which is already a formula.  Link to it.
      (progn
	;; See if we need to make the meta-schema inherit from the formula's
	;; parent.
	(if meta
	  (let ((parent-meta (find-meta form)))
	    (if parent-meta
	      (s-value meta :is-a (list parent-meta)))))
	(setf (a-formula-is-a formula) form)
	(setf (a-formula-function formula) (a-formula-function form))
	(setf (a-formula-lambda formula) (a-formula-lambda form))
	(push-one-or-list formula (a-formula-is-a-inv form)))
      ;; Normal case: we were given a Lisp expression
      (progn
	(setf (a-formula-function formula)
	      ;; This version does not work with CL version 2.  It is,
	      ;; however, much more efficient than calling the compiler.
	      #-(or CMU CCL ANSI-CL) `(lambda () ,form)
	      ;; This version works with CL version 2.
	      #+(or CMU CCL ANSI-CL) (compile nil `(lambda () ,form)))
	(setf (a-formula-lambda formula) form)))
    formula)))



;;;; FORMULA
;;; This version stores the formula as an INTERPRETED lambda.
;;; If <initial-value> is supplied, it is stored as the cached value for the
;;; formula; the formula, however, is still marked invalid.
;;; 
(defmacro formula (form &optional (initial-value nil) &rest slots)
  (if slots
      `(formula-fn ,form ,initial-value (create-schema nil ,@slots))
      `(formula-fn ,form ,initial-value NIL)))



(defun prepare-formula (initial-value)
  (locally (declare (optimize (speed 3) (space 0) #+(or ALLEGRO CCL) (debug 0)))
  (let ((formula (make-new-formula)))
    (setf (schema-name formula) (incf *schema-counter*))
    (setf (cached-value formula) initial-value)
    #+EAGER
    (setf (a-formula-bits formula) 0)
    #+EAGER
    (setf (a-formula-priority formula) *min-priority*)
    formula)))



(defun o-formula-fn (function lambda initial-value meta)
  (let ((formula (prepare-formula initial-value)))
    (setf (a-formula-function formula) function)
    (setf (a-formula-lambda formula) lambda)
    (setf (a-formula-meta formula) meta)
    formula))


;;;; O-FORMULA
;;; This version creates compilable formulas (but does not, by itself, actually
;;; compile them).
;;; 
(defmacro o-formula (form &optional (initial-value nil) &rest slots)
  (let ((meta NIL))
    (if slots
      (setf meta `(create-schema nil ,@slots)))
    (cond ((listp form)
	   `(o-formula-fn (function
			   (lambda ()
			    (declare (optimize (safety 1) (space 0)
					       (speed #-LUCID 3 #+LUCID 2)
					       #+(or ALLEGRO MCL) (debug 0)))
			    ,form))
	     ,(if *store-lambdas* `(quote ,form) nil)
	     ,initial-value
	     ,meta))
	  (meta
	   `(let ((meta ,meta))
	     (if (formula-p ',form)
	       ;; Just create an inherited formula
	       (formula ',form ,initial-value meta)
	       ;; This is a real o-formula
	       (let ((formula (prepare-formula ,initial-value)))
		 (setf (a-formula-function formula)
		       (function (lambda () ,form)))
		 (setf (a-formula-lambda formula) ',form)
		 (setf (a-formula-meta formula) meta)
		 formula))))
	  (T
	   `(if (formula-p ',form)
	     ;; Just create an inherited formula
	     (formula-fn ',form ,initial-value NIL)
	     ;; This is a real o-formula
	     (progn
	       (let ((formula (prepare-formula ,initial-value)))
		 (setf (a-formula-function formula)
		       (function (lambda () ,form)))
		 (setf (a-formula-lambda formula) ',form)
		 formula)))))))



;;; This function can be used to change a formula that was created using
;;; FORMULA into one that looks like it was created using O-FORMULA.  If
;;; <compile-p> is non-nil, the lambda expression of the formula is compiled.
;;;
;;; RETURNS:  the <formula>
;;;
(defun make-into-o-formula (formula &optional compile-p)
  (let ((form (if (listp (kr::a-formula-function formula))
		  (kr::a-formula-lambda formula))))
    (if form
	(setf (kr::a-formula-function formula)
	      (if compile-p
		  (compile nil `(lambda () ,form))
		  (eval `(function (lambda () ,form))))))
    formula))



;;;; CHANGE-FORMULA
;;; 
;;; Modify the function associated with a formula.  Several possible
;;; combinations exist:
;;; - If the function is local and there are no children, just go ahead and
;;;   invalidate the formula.
;;; - if the function is local and there are children, invalidate all the
;;;   children formulas as well.
;;; - if the function used to be inherited, replace it and eliminate the
;;;   link with the parent formula.
;;; 
(defun change-formula (schema slot form)
  "Modifies the formula at position 0 in the <slot> of the <schema> to have
  <form> as its new function.  Inherited formulas are treated appropriately."
  (let ((formula (get-value schema slot)))
    (when (formula-p formula)
      (when (a-formula-is-a formula)
	;; This function was inherited.  Cut the IS-A link.
	(let* ((parent (a-formula-is-a formula))
	       (inv (a-formula-is-a-inv parent)))
	  (setf (a-formula-is-a-inv parent)
		(if (listp inv)
		  (delete formula inv)
		  (if (eq inv formula) NIL inv))))
	(setf (a-formula-is-a formula) NIL))

      ;; If this formula has children, we need to invalidate them as well.
      (do-one-or-list (f-child (a-formula-is-a-inv formula))
	#-EAGER
	(set-cache-is-valid f-child nil)
	#-EAGER
	(mark-as-changed (on-schema f-child) (on-slot f-child))
	#+EAGER
	;; If this formula has children, we need to place them on the
	;; evaluation queue
	(setf *eval-queue* (insert-pq f-child *eval-queue*)))
      #-EAGER
      ;; Invalidate the formula itself.
      (set-cache-is-valid formula nil)
      #-EAGER
      (mark-as-changed schema slot)
      #+EAGER
      ;; Add the formula itself to the evaluation queue
      (setf *eval-queue* (insert-pq formula *eval-queue*))

      ;; Record the new function.
      (setf (a-formula-function formula) `(lambda () ,form))
      ;; store the new form in the lambda slot of the formula
      (setf (a-formula-lambda formula) form))))



;;;; MOVE-FORMULA
;;; 
;;; This function is used to move a formula from a slot to another.  It is
;;; not safe to simply do (s-value new :slot (get-value old :slot)),
;;; because this creates a formula which sits on two slots, and this is
;;; definitely a no-no.
;;; Any formula in to-schema.to-slot is destroyed, even if
;;; from-schema.from-slot contains a regular value (as opposed to a formula).
;;; 
(defun move-formula (from-schema from-slot to-schema to-slot)
  (let ((formula (get-value from-schema from-slot)))
    (if (formula-p formula)
	(let ((value (g-value-formula-value from-schema
					    from-slot formula NIL)))
	  (eliminate-formula-dependencies formula NIL)
	  ;; Invalidate the formula.
	  (set-cache-is-valid formula nil)
	  (setf (a-formula-schema formula) NIL)
	  (setf (a-formula-slot formula) NIL)
	  (setf (a-formula-depends-on formula) NIL)
	  (set-slot-accessor from-schema from-slot value *local-mask* NIL)
	  (s-value to-schema to-slot formula))
	;; This is just a regular value, not a formula.
	(let* ((entry (slot-accessor to-schema to-slot))
	       (value (if entry (sl-value entry))))
	  (when (formula-p value)
	    (destroy-constraint to-schema to-slot))
	  (s-value to-schema to-slot formula)))))



;;;; COPY-FORMULA
;;; Makes and returns a copy of the <formula>, keeping the same initial value
;;; and the same parent (if any).
;;; 
(defun copy-formula (formula)
  (let* ((parent (a-formula-is-a formula))
	 (value (a-formula-cached-value formula))
	 (new (formula parent value)))
    (unless parent
      ;; Copy lambda expression and compiled lambda.
      (setf (a-formula-function new) (a-formula-function formula))
      (setf (a-formula-lambda new) (a-formula-lambda formula)))
    (let ((meta (a-formula-meta formula)))
      (when meta
	(let ((new-meta (create-schema nil)))
	  (setf (a-formula-meta new) new-meta)
	  (doslots (slot meta)
	    (s-value new-meta slot (g-value meta slot))))))
    new))



;;; --------------------------------------------------


(defun broken-link-throw (schema slot)
  (declare (ignore schema))
  (when *current-formula*
    ;; 1. eliminate the dependencies from the formula, since they are no
    ;; longer accurate
    #+TEST (setf (a-formula-depends-on *current-formula*) nil)
    (setf *last-formula* *current-formula*)
    ;; 2. give warning if so desired.
    (if *warning-on-null-link*
	(format
	 t
	 "Warning: broken link in schema ~S (last slot ~S);~%~:
	 reusing stale value in formula ~S.~%"
	 *schema-self* slot *current-formula*))
    ;; 3. throw to the top level
    (throw 'no-link (a-formula-cached-value *current-formula*)))

  ;; We get here if a GV expression was used outside a formula
  (format
   t
   "*** Current formula seems to be missing.   You may have used GV or~%~:
   ~4TGVL in an expression outside a formula.  Last slot was ~s.~%"
   slot))



;;; RETURNS:
;;; T if the slot is not constant, i.e., it was not declared constant and we
;;; are not in the middle of a gv chain where the slot is declared a link
;;; constant.
;;;
(defun slot-is-not-constant (schema slot)
  (let ((entry (slot-accessor schema slot)))
    (if entry
      (not (is-constant (sl-bits entry))))))



;;; This is similar to g-value-fn, but does a few things needed for constant
;;; formula checking before it does anything else.  Also, sets up
;;; dependencies at the end.
;;;
(defun gv-value-fn (schema slot)
  (locally (declare (optimize (speed 3) (space 0) #+(or ALLEGRO CCL) (debug 0)))
  #+GARNET-DEBUG
  (unless (or *current-formula* (schema-p schema))
    (cerror "Return NIL" "  GV attempted on the non-object ~S (slot ~S)."
	    schema slot)
    (return-from gv-value-fn NIL))
  (if (or (null schema) (deleted-p schema))
    ;; Schema was destroyed
    (broken-link-throw schema slot))
  (let* ((setup T)
	 (entry (slot-accessor schema slot))
	 (value (if entry (sl-value entry) *no-value*)))
    (when (eq value *no-value*)
      (g-value-inherit-values schema slot T entry)
      (setf entry (slot-accessor schema slot))
      (if entry (setf value (sl-value entry))))
    (if (a-formula-p value)
      ;; we are working with a formula
      (setf value (g-value-formula-value schema slot value entry)
	    ;; This is necessary, because G-VALUE-FORMULA-VALUE may change
	    ;; the entry.
	    entry (slot-accessor schema slot)))
    (when *check-constants*
      (if (and entry (is-constant (sl-bits entry)))
	;; Constant, so do NOT set up dependencies.
	(setf setup NIL)
	;; Not constant
	(setf *is-constant* NIL))
      (setf *accessed-slots* T))
    ;; Now set up the dependencies.
    (when (and setup *current-formula*)	; do we need to set up dependencies?
      (if (null entry)
	(setf entry (set-slot-accessor schema slot *no-value* 0 NIL)))
      (unless (full-sl-p entry)
	;; We did have an entry, but it was too small.
 	(let ((full-entry (make-full-sl)))
 	  #+GARNET-BINS
 	  (do ((e (svref (schema-bins schema) (slot-to-bin-index slot)) (cdr e)))
	      ((eq (car e) entry)
	       (setf (car e) full-entry)))
	  #-GARNET-BINS
	  (setf (gethash slot (schema-bins schema)) full-entry)
	  (setf (sl-name full-entry) slot)
	  (if entry
	    (setf (sl-value full-entry) (sl-value entry)
		  (sl-bits full-entry) (sl-bits entry))
	    (setf (sl-value full-entry) value
		  (sl-bits full-entry) *local-mask*))
	  (setf entry full-entry)))
      (setup-dependency schema slot value entry))
    (if (not (eq value *no-value*)) value))))



;;; This macro generates the body of gv-local-fn.  The only
;;; difference is what accessor function to use.
;;;
(defmacro gv-fn-body (accessor-function)
  (let ((entry (gensym))
	(value (gensym))
	(the-value (gensym)))
    `(locally (declare ,*special-kr-optimization*)
      (if (eq schema :self)
	(setf schema *schema-self*))
      ;; Handle special relation slots which return a list of values.  In this
      ;; case, use the first value.  This code is for backward compatibility.
      (if (listp schema)
	(setf schema (car schema)))
      (if (schema-p schema)
	;; Schema is OK
	(if (if schema (not-deleted-p schema))
	  ;; Normal case
	  (let* ((,value (,accessor-function schema slot))
		 (,entry (slot-accessor schema slot))
		 (setup T))
	    (when *check-constants*
	      (if (and ,entry (is-constant (sl-bits ,entry)))
		;; If slot is constant, never set up a dependency.
		(setf setup NIL)
		(setf *is-constant* NIL))
	      (setf *accessed-slots* T)) ; indicate we have done something
	    ;; Record the link dependency for this parent and formula
	    (if (and setup *current-formula*)
	      (let ((,the-value (if ,entry (sl-value ,entry))))
		(setup-dependency schema slot (if (eq ,the-value *no-value*)
						*no-value* ,value)
				  ,entry)))
	    ,value)
	  ;; A link is broken.  Get out of here!
	  (broken-link-throw schema slot))
	;; Error!
	(if *current-formula*
	  ;; This happened inside a formula - broken link.
	  (progn
	    #+COMMENT  ;; amickish - 6/24/93
	    (format
	     t
	     "~%****~% ~S was found in a GV or GVL expression as an object name,
but is not a valid object.  This happened in the formula
in slot ~S of ~S.~%~%"
	     schema *schema-slot* *schema-self*)
	    (broken-link-throw schema slot))
	  ;; This happened at the top level.
	  #+GARNET-DEBUG
	  (cerror "Return NIL"
		  "GV or GVL on the non-schema ~S, slot ~S (not
inside a formula)"
		  schema slot))))))



;;; Set up a dependency: the *current-formula* depends on the <slot> of the
;;; <schema>.
;;;
(defun setup-dependency (schema slot value entry)
  (when *setup-dependencies*
    (unless (formula-p *current-formula*)
      (if (eq *current-formula* :IGNORE)
	;; This is used when evaluating expressions OUTSIDE formulas (by
	;; Gilt, for example) - just do nothing.
	(return-from setup-dependency schema))
      (cerror "Return NIL"
	      " (in setup-dependency) ~S is not a formula!~%"
	      *current-formula*)
      (return-from setup-dependency NIL))
    (unless schema
      ;; A link is broken.  Get out of here!
      (broken-link-throw schema slot))
    ;; Record the link dependency for this parent and formula
    (let ((dependents (slot-dependents entry)))
      (cond ((null dependents)
	      ;; No dependents yet.
	      (if (full-sl-p entry)
	        (setf (full-sl-dependents entry) *current-formula*)
	        ;; make sure we have a place on which to hang the dependency!
	        (let ((value (if entry (sl-value entry) value))
		      (bits  (if entry (sl-bits entry) 0)))
	          (setf entry (set-slot-accessor
			          schema slot value bits *current-formula*)))))
            ((listp dependents)
	      ;; List of dependents, make sure we're not there, then push
	      (if (memberq *current-formula* dependents)
	        (return-from setup-dependency NIL)
	        (setf (full-sl-dependents entry)
	              (cons *current-formula* dependents))))
            (T
	      ;; Just one dependent, make sure not the same, then make a list
	      (if (eq *current-formula* dependents)
	        (return-from setup-dependency NIL)
	        (setf (full-sl-dependents entry)
	              (list *current-formula* dependents))))))

    ;; We reach this point only if *current-formula* was not already one
    ;; of the dependents of <schema> <slot>.
    (let ((depended (a-formula-depends-on *current-formula*)))
     (cond ((null depended)
              (setf (a-formula-depends-on *current-formula*) schema))
           ((listp depended)
              (unless (memberq schema depended)
                (setf (a-formula-depends-on *current-formula*)
                      (cons schema depended))))
           (T
              (unless (eq schema depended)
                (setf (a-formula-depends-on *current-formula*)
                      (list schema depended))))))))



;;; This is used for chains of slots (i.e., links) in GV/GVL.  It keeps
;;; accessing slots until the end of the link.
;;;
(defun gv-chain (schema slot-descriptors)
  (do* ((s slot-descriptors (cdr s)))
       ((null s))
    (if (setf schema (gv-value-fn
		      ;; for backwards compatibility.
		      (if (listp schema) (car schema) schema)
		      (car s)))
      ;; We did get a schema.
      (if (eq schema :SELF)
	(setf schema *schema-self*))
      ;; There was no schema.  If we are in the middle, this is a broken link.
      (if (cdr s)
	(return (broken-link-throw schema (car s))))))
  schema)



;;;; GV
;;; To be used in formulas.
;;; This macro expands into a chain of value accesses, or a single call to
;;; gv-value-fn.
;;;
(defmacro gv (schema &rest slots)
  (cond
    (slots
     (if (and (keywordp schema) (not (eq schema :SELF)))
       ;; Missing object name!
       (cerror
	"Return NIL"
	"The first argument to GV must be an object.
Found in the expression   (gv ~S~{ ~S~}) ,~:[
  which appeared at the top level (i.e., not inside any formula)~;
  in the formula on slot ~S of object ~S~]."
	schema slots *current-formula*
	*schema-slot* *schema-self*)
       ;; No error
       (if (null (cdr slots))
	 ;; This is a GV with a single slot.
	 `(gv-value-fn ,(if (eq schema :self)
			  (setf schema '*schema-self*)
			  schema)
	   ,(car slots))
	 ;; this is the more general case
	 `(gv-chain ,(if (eq schema :self) '*schema-self* schema)
	   ,@(if (find-if-not #'keywordp slots)
	       ;; Some slot is not a keyword - use list.
	       `((list ,@slots))
	       ;; All slots are keywords - use literal.
	       `((quote ,slots)))))))
    ((eq schema :self)
     `(progn *schema-self*))
    (t
     `(progn ,schema))))




;;; Similar to GV-VALUE-FN, but only gets local values.
;;; 
(defun gv-local-fn (schema slot)
  (gv-fn-body g-local-value))



;;;; GV-LOCAL
;;; To be used in formulas.
;;; This macro expands into a chain of nested calls to gv-local-fn, which
;;; creates a dependency point in a formula.
;;;
(defmacro gv-local (schema &rest slots)
  (cond (slots
	 `(expand-accessor gv-local-fn ,schema ,@slots))
	((eq schema :self)
	 `(progn *schema-self*))
	(t
	 `(progn ,schema))))



;;;; GVL
;;; To be used in formulas.
;;; This is equivalent to a call to GV with a :SELF added as the first
;;; parameter.
;;; 
(defmacro gvl (name &rest names)
  `(gv *schema-self* ,name ,@names))


;;; --------------------------------------------------



;;; This is the default invalidate demon.
;;; 
(defun invalidate-demon (schema slot save)
  (kr-send schema :UPDATE-DEMON schema slot save))




;;;; DESTROY-CONSTRAINT
;;; Replaces the formula in the <slot> with its value, physically eliminating
;;; the constraint.  If there is no formula, <schema> is unchanged.
;;; 
(defun destroy-constraint (schema slot)
  "If the value in the <slot> of the <schema> is a formula, replace it with
  the current value of the formula and eliminate the formula.  This
  effectively eliminates the constraint on the value."
  (let* ((entry (slot-accessor schema slot))
	 (formula (if entry
		    (sl-value entry)
		    (g-value-inherit-values schema slot T entry))))
    (when (and (formula-p formula)
	       (not-deleted-p formula))	; not already deleted
      (let ((value (g-cached-value schema slot)))
	;; All children formulas are eliminated as well.
	(do-one-or-list (child (a-formula-is-a-inv formula))
	  (when (not-deleted-p child)	; do nothing if already deleted.
	    (g-value (on-schema child) (on-slot child))	; get value
	    (destroy-constraint (on-schema child) (on-slot child))))
	;; Inform dependents, even if value does not change.  This is
	;; for applications (such as C32) which need to know whether a
	;; formula is present.
	(mark-as-changed schema slot)
	(delete-formula formula T)
	;; Replace formula with its cached value.
	(set-slot-accessor schema slot value
			   ;; Keep the update-slot bit
			   (logior *local-mask* (logand (sl-bits entry)
							*is-update-slot-mask*))
			   NIL)
	NIL))))



;;; ---------------------------------------------- INITIALIZE THE WHOLE THING


;;;; INITIALIZE-KR
;;; 
;;; Call once at the beginning.
;;; 
(defun initialize-kr ()
  (setf *relations* nil)
  (setf *inheritance-relations* nil)
  #+EAGER
  ;; set up the priority list
  (init-priority-list)

  ;; Create the IS-A relation, which should come first in the list.
  (create-relation :IS-A T :IS-A-INV)
  ;; Create the default schema which controls the behavior of PS
  ;; 
  (create-schema 'PRINT-SCHEMA-CONTROL
    ;; Names of slots which should be printed out first, in the right order.
    (:sorted-slots :left :top :width :height)
    ;; A list of slots and maximum numbers.  If the number of values in a slot
    ;; exceed the limit, ellipsis will be printed.
    (:limit-values '(:IS-A-INV 5) '(:COMPONENTS 20))
    ;; Maximum limit for number of values (global).
    (:global-limit-values 10)))


(initialize-kr)




;;; --------------------------------------------------

;;; moved here because of a strange loading problem.

;;;; IS-A-P
;;; 
;;; Test whether <schema> IS-A <type>, either directly or indirectly.
;;; 
(defun is-a-p (schema type)
  "Tests whether the <schema> is linked via :IS-A to schema <type>, either
  directly or through several links.  Note that (is-a-p <schema> T) returns
  true if <schema> is a schema."

  (if (null schema)
    (return-from is-a-p (or (null type) (eq type T))))

  (if (formula-p schema)
    ;; A formula.
    (if (or (eq type T)
	    (eq schema type)
	    (eq (a-formula-is-a schema) type))
      T
      (is-a-p (a-formula-is-a schema) type))
    ;; A schema.
    (when (schema-p schema)
      (or (eq type T)			; (is-a-p any-schema T) is true
	  (eq schema type)		; (is-a-p foo foo) is true
	  (dolist (parent (g-value schema :IS-A))
	    (if (eq parent type)
	      (return-from is-a-p T)))
	  ;; Not directly in the list: how about the parents?
	  (dolist (parent (g-value schema :IS-A))
	    (if (is-a-p parent type)
	      (return-from is-a-p t)))))))



;;; Given an object and a slot, if the <slot> contains a formula it returns
;;; all the slots upon which the formula depends.  The result is a list of
;;; dotted pairs, where each pair consists of a schema and a slot.
;;;
(defun i-depend-on (object slot)
  (locally (declare (optimize (speed 3) (space 0) #+(or ALLEGRO CCL) (debug 0)))
  (if (schema-p object)
    (let ((formula (get-value object slot))
	  (dependencies nil))
      (if (formula-p formula)
	(do-one-or-list (schema (a-formula-depends-on formula))
	  (iterate-slot-value (schema T T T)
	    (if (not (eq value *no-value*))
	      (do-one-or-list (f (slot-dependents
				  kr::iterate-slot-value-entry))
		(if (eq f formula)
		  (push (cons schema slot) dependencies)))))))
      dependencies)
    ;; An error
    (cerror
     "Return NIL"
     "I-DEPEND-ON called on the ~:[non-~;destroyed ~]object ~S."
     (is-schema object) object))))




;;; Used in a formula, returns the cached value.
;;;
(defun self-old-value ()
  (if *current-formula*
    (let ((value (a-formula-cached-value *current-formula*)))
      (if (eq value *no-value*)
	  NIL
	  value))))



;;; --------------------------------------------------

;;; Define basic builtin types.  These definitions must come after the
;;; file KR.LISP is loaded.
;;;

(def-kr-type kr-no-type () '(satisfies no-type-error-p)
	     "No type defined for this slot")

;;; We want 0 to mean "no type".
(setf (aref types-array 0) NIL)

;; Make this the first type
(def-kr-type kr-boolean () T
	     "Any value is legal")


(dolist (type '(null string keyword integer number list cons schema))
  (encode-type type))




;;; --------------------  Proclaim that the system was loaded successfully

(setf (get :garnet-modules :KR) t)
