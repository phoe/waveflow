;;;; flow.lisp

(in-package #:waveflow)

;;; COMPUTE-EXECUTION-STATUS

(defvar *executed-waves*)

(defvar *executing-waves*)

(defgeneric compute-execution-status (wave dependencies)
  (:documentation "Returns if the wave should be executed now based on whether
its dependencies have been executed.")
  (:method ((wave wave) dependencies)
    (dolist (dependency dependencies)
      (unless (gethash dependency *executed-waves*)
        (return-from compute-execution-status nil)))
    (when (or (gethash (name wave) *executing-waves*)
              (gethash (name wave) *executed-waves*))
      (return-from compute-execution-status nil))
    (setf (gethash (name wave) *executing-waves*) t)
    t))

(defgeneric after-execution (wave dependencies)
  (:documentation "Side effects after wave execution.")
  (:method ((wave wave) dependencies)
    (declare (ignore dependencies))
    (setf (gethash (name wave) *executed-waves*) t)))

;;; WAVEFLOW-ERROR

(define-condition waveflow-error (error) ())

(define-condition simple-waveflow-error (waveflow-error simple-condition) ())

(declaim (inline waveflow-error))

(defun waveflow-error (format-control &rest args)
  (error (make-condition 'simple-waveflow-error
                         :format-control format-control
                         :format-arguments args)))

(defvar *waveflow-error-format*
  "Wave ~S finished unsuccessfully with arguments ~S.")

;;; FIND-FLOW and (SETF FIND-FLOW)

(defvar *flows* (make-hash-table))

(defun find-flow (name)
  (values (gethash name *flows*)))

(defun (setf find-flow) (new-value name)
  (check-type new-value (or null flow))
  (if new-value
      (setf (gethash name *flows*) new-value)
      (remhash name *flows*))
  new-value)

;;; FLOW

(defclass flow ()
  ((%name :accessor name
          :initarg :name)
   (%spawn-fn :accessor spawn-fn
              :initarg :spawn-fn)
   (%waves :accessor waves
           :initarg :waves))
  (:default-initargs :name (waveflow-error "Must provide NAME.")
                     :waves (waveflow-error "Must provide WAVES.")
                     :spawn-fn #'execute-wave))

(defmethod print-object ((object flow) stream)
  (print-unreadable-object (object stream :type t)
    (princ (name object) stream)))

(defun wave-dependency-list-p (list)
  (and (listp list)
       (every (lambda (x) (= 2 (length x))) list)
       (setp list :test #'equal)
       (loop for (dependency dependent) in list
             unless (and (symbolp dependency) (symbolp dependent))
               return nil
             finally (return t))))

(defmethod initialize-instance :after ((flow flow) &key)
  (check-type (name flow) symbol)
  (check-type (spawn-fn flow) function)
  (assert (wave-dependency-list-p (waves flow)) ((waves flow))
          "Invalid wave dependency list: ~S" (waves flow))
  (multiple-value-bind (cyclicp symbol) (circular-graph-p (waves flow))
    (when cyclicp (waveflow-error "Cycle detected for wave ~S." symbol)))
  (when (nth-value 1 (gethash (name flow) *flows*))
    (warn "Redefining flow ~S" (name flow)))
  (setf (gethash (name flow) *flows*) flow))

;;; EXECUTE-FLOW

(defvar *current-flow*)

(defgeneric execute-flow (flow &rest args)
  (:documentation "Returns no meaningful value."))

(defmethod execute-flow ((flow symbol) &rest args)
  (apply #'execute-flow (find-flow flow) args))

(defmethod execute-flow :around ((flow flow) &rest args)
  (declare (ignore args))
  (let ((*current-flow* flow)
        (*executing-waves* (make-hash-table))
        (*executed-waves* (make-hash-table)))
    (call-next-method)
    (values)))

(defmethod execute-flow ((flow flow) &rest args)
  (let ((roots (mapcar #'find-wave (graph-roots (waves flow))))
        (spawn-fn (spawn-fn flow)))
    (loop for root in roots
          do (apply spawn-fn root args))))

(declaim (inline flow-dependencies-dependents))

(defun flow-dependencies-dependents (wave)
  (loop with name = (name wave)
        for (dependency dependent) in (waves *current-flow*)
        when (eq dependent name)
          collect dependency into dependencies
        when (eq dependency name)
          collect dependent into dependents
        finally (return (values dependencies dependents))))

(defmethod execute-wave :around ((wave executable-wave) &rest args)
  (if (not (boundp '*current-flow*))
      (call-next-method)
      (multiple-value-bind (dependencies dependents)
          (flow-dependencies-dependents wave)
        (when (compute-execution-status wave dependencies)
          (multiple-value-bind (successp data) (call-next-method)
            (unless successp
              (waveflow-error *waveflow-error-format* wave args))
            (after-execution wave dependencies)
            (loop with spawn-fn = (spawn-fn *current-flow*)
                  for wave in (mapcar #'find-wave dependents)
                  do (apply spawn-fn wave args))
            ;; TODO this may blow the stack; the flow must be the only thing to
            ;; execute waves, a wave must not execute other waves
            (values successp data))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;; TODO ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; (defmacro define-flow (name options &body forms)
;;   (check-type name symbol)
;;   (let ((first-wave (caar forms))
;;         (prepare-fn (getf options :prepare-fn))
;;         (class (or (getf options :class) 'standard-flow))
;;         (next-waves (mapcar (curry #'remove '->) forms)))
;;     (with-gensyms (instance)
;;       `(let ((,instance (make-flow ',name ,prepare-fn
;;                                    ',first-wave ',next-waves ',class)))
;;          (setf (gethash ',name *flows*) ,instance)
;;          ',name))))

;; (define-flow synchronize (:prepare-fn 'synchronize-prepare)
;;   (login            -> download-account)
;;   (download-account -> download-furres
;;                     -> download-images)
;;   (download-furres  -> download-costumes
;;                     -> download-portraits
;;                     -> download-specitags))
