(in-package :mulm)

;; TODO lm-tag-tree and suffix-tree must be estimated from counts 

(defparameter *estimation-cutoff* 0)

(defstruct hmm
  ; all unique tokens seen by the model with mapping to integer code
  (token-lexicon (make-lexicon))
  ; all unique tags seen by the model with mapping to integer code
  (tag-lexicon (make-lexicon))
  ; total amount of tokens in the training material seen by the model
  (token-count 0)
  ; number of tags seen in the training data
  ; NOTE see hmm-tag-cardinality() for number of tags used during training
  ; and decoding
  (n 0)
  
  tag-array
  beam-array

  ;; 2D array containing transition probabilities, indexed on tag code
  transitions
  ;; array indexed on tag codes containing maps with token codes as keys
  ;; and log probs as values
  emissions

  ;; 3d array indexed on tag codes with probs
  trigram-table
  ;; array indexed on tag codes with probs
  unigram-table

  ;; only used during training
  tag-lm

  ;; tag n-gram counts from the corpora
  unigram-counts
  bigram-counts
  trigram-counts
  
  ;; deleted interpolation lambdas:
  (lambda-1 0.0 :type single-float)
  (lambda-2 0.0 :type single-float)
  (lambda-3 0.0 :type single-float)
  ;; KN-d for bigrams
  bigram-d
  ;; KN-d for trigrams
  trigram-d
  ;; Sufffix tries for the word model
  (suffix-tries (make-hash-table :test #'equal))
  ;; theta-parameter for TnT style word model
  theta
  
  trigram-transition-table ;; actual trigram transitions with log-probs used by decoder
  bigram-transition-table ;; actual bigram transitions with log-probs used by decoder
  caches ;; transient caches for decoding
  )

;; NOTE tag cardinality is the total number of tags used by the model, ie. start and end
;; tags are added to the tag set. N is the number of tags seen in the training data.
(defun hmm-tag-cardinality (hmm)
  (+ (hmm-n hmm) 2))

(defun bigram-to-code (hmm bigram)
  "Returns index of bigram data in "
  (let ((c1 (token-to-code (first bigram)
                           (hmm-tag-lexicon hmm)
                           :rop t))
        (c2 (token-to-code (second bigram)
                           (hmm-tag-lexicon hmm)
                           :rop t)))
    (+ (* c1 (hmm-tag-cardinality hmm))
       c2)))

(defmethod print-object ((object hmm) stream)
  (format stream "<HMM with ~a states>" (hmm-n object)))

(defun transition-probability (hmm current previous &optional t2 &key (order 1) (smoothing :constant))
  "Calculates the transition-probability given previous states (atom if bigram, list of prev it trigram"
  (declare (type fixnum current order))
  (declare (type hmm hmm))
  (when (keywordp t2)
    (error "Illegal arglist"))
  (log
   (cond ((and (eql order 1) (eql smoothing :constant))
          (or (aref (the (simple-array t (* *)) (hmm-transitions hmm)) previous current) 0.000001))
         ((and (= order 1) (eql smoothing :deleted-interpolation))
          (+
           (* (the single-float (hmm-lambda-1 hmm))
              (or (aref (the (simple-array t (*)) (hmm-unigram-table hmm)) current)
                  0.0))
           (the single-float
             (* (hmm-lambda-2 hmm)
                (or (aref (the (simple-array t (* *)) (hmm-transitions hmm)) previous current)
                    0.0)))))
         ((and (= order 2) (eql smoothing :simple-back-off))
          (or (aref (the (simple-array  t (* * *))
                      (hmm-trigram-table hmm))
                    (first previous) (second previous) current)
              (aref (the (simple-array t (* *)) (hmm-transitions hmm))
                    (second previous) current)
              (aref (the (simple-array t (*))
                      (hmm-unigram-table hmm))
                    current)
              0.00000001))
         ((and (= order 2) (eql smoothing :deleted-interpolation))
          (let ((lambda-1 (hmm-lambda-1 hmm))
                (lambda-2 (hmm-lambda-2 hmm))
                (lambda-3 (hmm-lambda-3 hmm))
                (t1 previous)
                (t2 t2))
            (declare (type fixnum t1 t2))
            (declare (type single-float lambda-1 lambda-2 lambda-3))
            (let* ((unigram (* lambda-1 
                               (the single-float (or (aref (the (simple-array t (*)) (hmm-unigram-table hmm)) current)
                                                     0.0))))
                   (bigram (* lambda-2
                              (the single-float (or (aref (the (simple-array t (* *)) (hmm-transitions hmm)) 
                                                          t2 current)
                                                    0.0))))
                   (trigram (* lambda-3
                               (the single-float (or (aref (the (simple-array t (* * *)) (hmm-trigram-table hmm)) 
                                                           t1 t2 current)
                                                     0.0)))))
              (declare (type single-float unigram bigram trigram))
              (+ unigram bigram trigram))))
         
         (t (error "Illegal type of transition, check parameters!")))))

(defun make-transition-table (hmm order smoothing)
  "Creates a cached transition table by calling transition-probability"
  (let ((tag-card (hmm-tag-cardinality hmm)))
    (declare (type fixnum tag-card))
    (cond
     ((= order 1)
      (setf (hmm-bigram-transition-table hmm)              
        (let* ((table (make-array (list tag-card tag-card) :element-type 'single-float :initial-element 0.0)))
          (loop
              for i from 0 below tag-card
              do (loop
                     for j below tag-card do
                       (setf (aref table i j) (transition-probability hmm j i nil :order 1 :smoothing smoothing))))
          table)))
     ((= order 2)
      (setf (hmm-trigram-transition-table hmm)
        (let* ((table (make-array (list tag-card tag-card tag-card) 
                                  :element-type 'single-float :initial-element most-negative-single-float)))
          
          ;;; This loop is very expensive (often several times so than
          ;;; decoding a fold) on hmms with large tag-sets perhaps a
          ;;; memoization technique is better suited here
          
          (loop
              for i fixnum from 0 below tag-card
              do (loop 
                     for j fixnum from 0 below tag-card                                         
                     do (loop
                            for k fixnum from 0 below tag-card do
                              (setf (aref (the (simple-array single-float (* * *)) table) i j k) 
                                (transition-probability hmm k i j :order 2 :smoothing smoothing)))))
          table)))
     (t (error "Illegal type of transition, check parameters!")))))

(defmacro bi-cached-transition (hmm from to)
  "Gets the cached transition probability from tag `from' to tag `to'
   given `hmm'."
  `(the single-float  
     (aref (the (simple-array single-float (* *)) (hmm-bigram-transition-table ,hmm)) ,from ,to)))

(defmacro tri-cached-transition (hmm t1 t2 to)
  "Gets the cached transition probability P(to|t1,t2)"
  `(the single-float
     (max -19.0
          (aref (the (simple-array single-float (* * *)) (hmm-trigram-transition-table ,hmm)) ,t1 ,t2 ,to))))

(defmacro emission-probability (hmm state form)
  "Gets the probability P(e|t)"
  `(the single-float (or (gethash ,form (aref (the (simple-array t (*)) (hmm-emissions ,hmm)) ,state)) -19.0)))

(defun emission-probability-slow (decoder hmm state form)
  (if (unknown-token-p hmm form)
    (let* ((form (token-to-code (second form)
                                (hmm-token-lexicon hmm) :rop t))
           (cache (gethash :unknown-word (viterbi-decoder-caches decoder)))
           (cache-lookup (gethash form cache))
           (dist (or cache-lookup
                     (let ((dist (query-suffix-trie hmm form)))
                       (setf (gethash form cache) dist)
                       dist))))
      (aref dist state))
    (the single-float
         (gethash form
                  (aref (the (simple-array t (*)) (hmm-emissions hmm)) state)
                  -19.0))))

;; WARNING this function processes the entire corpus
(defun corpus-tag-set-size (corpus)
  "Returns the number of unique tags observed in the corpus."
  (let ((tag-map (make-hash-table :test #'equal)))
    (loop for sentence in corpus
          do (loop for token in sentence
                   do (if (not (gethash (second token) tag-map))
                        (setf (gethash (second token) tag-map) t))))
    (hash-table-count tag-map)))

;; WARNING does not fully initialize the hmm data structure.
;; Do not use this function to reuse hmm structs.
(defun setup-hmm (hmm n &optional (partial nil))
  "Initializes the basic (but not all) hmm model data structures.
   hmm - Instantiated hmm struct.
   n   - Model tag set size.
   Returns the passed hmm struct."
  (setf (hmm-n hmm) n)
  
  ;; add start and end tags to tag set size
  (let ((n (hmm-tag-cardinality hmm)))
    ;; do not fill in these when deserializing
    (when (not partial)
      (setf (hmm-token-count hmm) 0))

    ;; setup tables for tag n-gram counts
    (setf (hmm-unigram-counts hmm)
          (make-array n :initial-element 0 :element-type 'fixnum))
    (setf (hmm-bigram-counts hmm)
          (make-array (list n n) :initial-element 0 :element-type 'fixnum))
    (setf (hmm-trigram-counts hmm)
          (make-array (list n n n) :initial-element 0 :element-type 'fixnum))
    
    ;; setup empty tables for probability estimates
    (setf (hmm-transitions hmm)
          (make-array (list n n) :initial-element nil))
    (setf (hmm-emissions hmm)
          (make-array n :initial-element nil))
    (setf (hmm-trigram-table hmm)
          (make-array (list n n n) :initial-element nil))
    (setf (hmm-unigram-table hmm)
          (make-array n :initial-element nil))
    (loop for i from 0 to (- n 1)
        do (setf (aref (hmm-emissions hmm) i) (make-hash-table :size 11)))
    (setf (hmm-caches hmm)
      (list 
       ;;; We try to prevent newspace expansion here: these caches
       ;;; will live as long as the hmm-struct they belong to it is
       ;;; therefore likely that they will eventually be tenured
       ;;; anyway. it should be better to not have these clogging up
       ;;; newspace and being scavenged around
       (make-array (list (* n n) 100) :initial-element nil) ;; backpointer table
       (make-array (list (* n n) 100) 
                   :initial-element most-negative-single-float 
                   :element-type 'single-float) ;; trellis
       (make-array (* n n) :initial-element 0 :fill-pointer 0 :element-type 'fixnum) ;; first agenda
       (make-array (* n n) :initial-element 0 :fill-pointer 0 :element-type 'fixnum))))
  hmm)

(defun calculate-tag-lm (hmm corpus)
  (let ((lm-root (make-lm-tree-node))
        (n (hmm-tag-cardinality hmm)))
    ;;; this is quite hacky but count-trees will be abstracted nicely
    ;;; in the near future, however, this should estimate correct
    ;;; n-gram probabilities
    (loop initially (build-model (mapcar (lambda (x)
                                           (append
                                            (list (token-to-code "<s>" (hmm-tag-lexicon hmm) :rop t))
                                            (mapcar (lambda (x)

                                                      (token-to-code x (hmm-tag-lexicon hmm) :rop t))
                                                    x)
                                            (list (token-to-code  "</s>" (hmm-tag-lexicon hmm) :rop t))))
                                         (ll-to-tag-list corpus))
                                 3
                                 lm-root)
          for t1 from 0 below n
          for t1-node = (getlash t1 (lm-tree-node-children lm-root))
          when t1-node do
          (loop 
           for t2 from 0 below n 
           for t2-node = (getlash t2 (lm-tree-node-children t1-node))
           when t2-node do
           (loop 
            with total = (float (lm-tree-node-total t2-node))
            for t3 from 0 below n
            for t3-node = (getlash t3 (lm-tree-node-children t2-node))
            when t3-node do
            (let ((prob (/ (lm-tree-node-total t3-node)
                           total)))
              (setf (aref (hmm-trigram-table hmm) t1 t2 t3)
                    prob)))))
    lm-root))

(defun setup-hmm-beam (hmm)
  "Initializes the hmm struct fields concerning the beam search.
   hmm - Instantiated hmm struct.
   Returns the passed hmm struct."
  (let ((n (hmm-tag-cardinality hmm)))
    (setf (hmm-beam-array hmm) (make-array n :fill-pointer t))
    (setf (hmm-tag-array hmm)
          (make-array n :element-type 'fixnum 
                      :initial-contents (loop for i from 0 to (1- n) collect i))))
  hmm)


;; prepare bigram and trigram generators.
(defparameter *bigram-stream* (make-partition-stream nil 2))
(defparameter *trigram-stream* (make-partition-stream nil 3))

(defun add-sentence-to-hmm (hmm sentence)
  "Adds emission, tag unigram, bigram and trigram counts to the appropriate fields
   in the hmm struct.
   hmm - Instantiated hmm struct.
   sentence - In list of lists format.
   Returns the passed hmm struct."
  ;; Add start and end tags
  (let* ((unigrams (append '("<s>")
                           (mapcar #'second sentence)
                           '("</s>"))))
                                        ;(bigrams (partition unigrams 2)))
                                        ;(trigrams (partition unigrams 3)))
    (funcall *bigram-stream* :reset unigrams)
    (funcall *trigram-stream* :reset unigrams)
    (loop for (token tag) in sentence
        for code = (token-to-code token (hmm-token-lexicon hmm))
        do (incf (hmm-token-count hmm))
        do (incf (gethash code
                          (aref (hmm-emissions hmm)
                                (token-to-code tag (hmm-tag-lexicon hmm)))
                          0)))

    (loop for unigram in unigrams
        for code = (token-to-code unigram (hmm-tag-lexicon hmm))
        do (incf (aref (hmm-unigram-counts hmm) code)))
    
    (loop with stream = *bigram-stream*
        for bigram = (funcall stream)
        while bigram
        for previous = (token-to-code (first bigram) (hmm-tag-lexicon hmm))
        for current = (token-to-code (second bigram) (hmm-tag-lexicon hmm))
        do (incf (aref (hmm-bigram-counts hmm) previous current)))

    (loop 
        with stream = *trigram-stream*
        for trigram = (funcall stream)
        while trigram
              
        do (let ((t1 (token-to-code (first trigram) (hmm-tag-lexicon hmm)))
                 (t2 (token-to-code (second trigram) (hmm-tag-lexicon hmm)))
                 (t3 (token-to-code (third trigram) (hmm-tag-lexicon hmm))))
             (incf (aref (hmm-trigram-counts hmm) t1 t2 t3))))
    hmm))

(defun populate-counts (corpus hmm)
  "Add all the sentences in the corpus to the hmm"
  (loop for sentence in corpus
      do (add-sentence-to-hmm hmm sentence)))

(defun train (corpus &optional (n nil))
  "Trains a HMM model from a corpus (a list of lists of word/tag pairs).
   Returns a fully trained hmm struct."

  ;; determine tagset size if not specified by the n parameter
  (let ((hmm (setup-hmm (make-hmm) (or n (corpus-tag-set-size corpus)))))
    ;; collect counts from setences in the corpus
    (populate-counts corpus hmm)

    (setup-hmm-beam hmm)

    ;; These steps must be performed before counts are converted into
    ;; probability estimates
    (calculate-deleted-interpolation-weights hmm)
    (calculate-theta hmm)
    (build-suffix-tries hmm)
    (setf (hmm-bigram-d hmm)
          (estimate-bigram-d hmm))
    (setf (hmm-trigram-d hmm)
      (estimate-trigram-d hmm))
    
    ;; Now we can prepare normalized probabilites:
    
    (let ((n (hmm-tag-cardinality hmm)))
      
      (loop
       with bigram-counts = (hmm-bigram-counts hmm)
       with transitions of-type (simple-array t (* *))  = (hmm-transitions hmm)
       for i fixnum from 0 to (- n 1)
       ;;; Get the total amount of this tag (isnt this in unigram-table?)
       for total fixnum = (float (loop
                                  for j  fixnum from 0 to (- n 1)
                                  for count = (aref bigram-counts i j)
                                  when (and count (> count *estimation-cutoff*))
                                  sum count))
       do
       ;;; Normalize bigrams
       (loop
        for j from 0 to (- n 1)
        for count = (aref bigram-counts i j)
        when (and count (> count *estimation-cutoff*))
        do (setf (aref transitions i j) (float (/ count total))))
            
       ;;; Adjust counts for emissions with Good-Turing
       (make-good-turing-estimate (aref (hmm-emissions hmm) i)
                                  (hash-table-sum (aref (hmm-emissions hmm) i))
                                  (code-to-token i (hmm-tag-lexicon hmm)))
            
       ;;; Normalize emissions
       (loop
        with map = (aref (hmm-emissions hmm) i)
        for code being each hash-key in map
        for count = (gethash code map)
        when (and count (> count *estimation-cutoff*))
        do (setf (gethash code map) (float (log (/ count total))))))
      
      
      ;;; Normalize trigrams:
      (setf (hmm-tag-lm hmm) (calculate-tag-lm hmm corpus))
      
      
      ;;; Normalize unigrams:
      (loop for i from 0 below n
          for count = (aref (hmm-unigram-counts hmm) i)
          with total = (loop for count across (hmm-unigram-counts hmm)
                             summing count)
                       ;; TODO discrepancy between token count and unigram count total
                       ;; with total = (hmm-token-count hmm)
          do (setf (aref (hmm-unigram-table hmm) i)
               (float (/ count total)))))
    
    hmm))

(defun calculate-theta (hmm)
   (let* ((total (loop for count across (hmm-unigram-counts hmm)
                       summing count))
          (probs (loop for count across (hmm-unigram-counts hmm)
                       collect (float (/ count total))))
          (mean (/ (loop for p in probs
                         summing p)
                   (hmm-tag-cardinality hmm))))
     (setf (hmm-theta hmm)
           (sqrt (float (* (/ 1.0 (1- (hmm-tag-cardinality hmm)))
                           (loop 
                            for p in probs
                            summing (expt (- p mean) 2))))))))

(defun add-to-suffix-tries (hmm word tag count)
  (let* ((form (code-to-token word (hmm-token-lexicon hmm)))
         (trie-key (capitalized-p form))
         (lookup (gethash trie-key (hmm-suffix-tries hmm))))
    (when (null lookup)
      (setf lookup (make-lm-tree-node))
      (setf (gethash trie-key (hmm-suffix-tries hmm))
            lookup))
    (add-word hmm word tag count lookup)))

(defun total-emissions (code hmm)
  (loop
      for table across (hmm-emissions hmm)
      summing (gethash code table 0)))

(defun build-suffix-tries (hmm)
  (loop 
      for state below (hmm-tag-cardinality hmm)
      for emission-map = (aref (hmm-emissions hmm) state)
       do
        (loop 
            for word being the hash-keys in emission-map
            for count = (gethash word emission-map)
            when (and (<= count 10) (<= (total-emissions word hmm) 10)
                      (not (eql word :unk)))                       
            do (add-to-suffix-tries hmm word state count)))
  (maphash (lambda (k v)
             (declare (ignore k))
             (compute-suffix-trie-weights v))
           (hmm-suffix-tries hmm)))

(defun calculate-deleted-interpolation-weights (hmm)
  (let ((lambda-1 0)
        (lambda-2 0)
        (lambda-3 0)
        (n (hmm-tag-cardinality hmm))
        (uni-total (loop for count across (hmm-unigram-counts hmm)
                         summing count)))
    (loop for i from 0 below n
          do (loop for j from 0 below n
                   do (loop for k from 0 below n
                            for tri-count = (aref (hmm-trigram-counts hmm) i j k)
                            when tri-count
                            do (let* ((bi-count (aref (hmm-bigram-counts hmm) j k))
                                      (uni-count (aref (hmm-unigram-counts hmm) k))
                                      (c1 (let ((bi-count (aref (hmm-bigram-counts hmm) i j)))
                                            (if (and bi-count
                                                     (> bi-count 1)
                                                     (> bi-count *estimation-cutoff*))
                                              (/ (1- tri-count)
                                                 (1- bi-count))
                                              0)))
                                      (c2 (let ((uni-count (aref (hmm-unigram-counts hmm) j)))
                                            (if (and uni-count
                                                     (> uni-count 1)
                                                     (> uni-count *estimation-cutoff*))
                                              (/ (1- bi-count)
                                                 (1- uni-count))
                                              0)))
                                      (c3 (/ (1- uni-count)
                                             (1- uni-total))))
                                 (cond ((and (>= c3 c2) (>= c3 c1))
                                        (incf lambda-3 tri-count))
                                       ((and (>= c2 c3) (>= c2 c1))
                                        (incf lambda-2 tri-count))
                                       ((and (>= c1 c3) (>= c1 c2))
                                        (incf lambda-1 tri-count))
                                       (t (error "Mysterious frequencies in DI-calculation.")))))))
    ;; i have no idea why inverting these makes everyhing so much better
    ;; is there a bug somewhere?
    (let ((total (+ lambda-1 lambda-2 lambda-3)))
      (setf (hmm-lambda-3 hmm) (float (/ lambda-1 total)))
      (setf (hmm-lambda-2 hmm) (float (/ lambda-2 total)))
      (setf (hmm-lambda-1 hmm) (float (/ lambda-3 total)))
      hmm)))


(defun code-to-bigram (hmm bigram)
  (list (code-to-token (floor (/ bigram (hmm-tag-cardinality hmm)))
                       (hmm-tag-lexicon hmm))
        (code-to-token (mod bigram (hmm-tag-cardinality hmm))
                       (hmm-tag-lexicon hmm))))


;; WARNING serialization and deserialization is currently inaccurate

;; Serialization
(defun serialize-hmm-model-header (hmm s)
  (format s "hmm header n ~a token-count ~a~%" (hmm-tag-cardinality hmm) (hmm-token-count hmm)))

(defun serialize-hmm-transitions (hmm s)
  (format s "hmm transitions start~%")
  (loop for i from 0 below (hmm-tag-cardinality hmm)
        do (loop for j from 0 below (hmm-tag-cardinality hmm)
                 do (format s "~a ~a ~S~%"
                            i j (aref (hmm-transitions hmm) i j))))
  (format s "hmm transitions end~%"))

(defun serialize-hmm-emissions (hmm s)
  (format s "hmm emissions start~%")
  (loop for map across (hmm-emissions hmm)
        for i from 0
        do (loop for j being the hash-keys of map
                   for val being the hash-values of map
                   do (format s "~a ~a ~S~%" i j val)))
  (format s "hmm emissions end~%"))

(defun serialize-hmm-trigram-table (hmm s)
  (format s "hmm trigram table start~%")
  (loop for i from 0 below (hmm-tag-cardinality hmm)
        do (loop for j from 0 below (hmm-tag-cardinality hmm)
                 do (loop for k from 0 below (hmm-tag-cardinality hmm)
                          when (aref (hmm-trigram-table hmm) i j k)
                          do (format s "~a ~a ~a ~S~%"
                                     i j k
                                     (aref (hmm-trigram-table hmm) i j k)))))
  (format s "hmm trigram table end~%"))

(defun serialize-hmm-unigram-table (hmm s)
  (format s "hmm unigram table start~%")
  (loop for i from 0 below (hmm-tag-cardinality hmm)
        do (format s "~a ~S~%"
                   i (aref (hmm-unigram-table hmm) i)))
  (format s "hmm unigram table end~%"))

(defun serialize-hmm-parameters (hmm s)
  (format s "hmm parameters start~%")

  (format s "lambda-1 ~S~%" (hmm-lambda-1 hmm))
  (format s "lambda-2 ~S~%" (hmm-lambda-2 hmm))
  (format s "lambda-3 ~S~%" (hmm-lambda-3 hmm))
  (format s "theta ~S~%" (hmm-theta hmm))
  (format s "bigram-d ~S~%" (hmm-bigram-d hmm))
  (format s "trigram-d ~S~%" (hmm-trigram-d hmm))

  (format s "hmm parameters end~%"))

(defun serialize-hmm-model (hmm s)
  (serialize-hmm-model-header hmm s)
  (serialize-lexicon (hmm-tag-lexicon hmm) s :hmm-tag-lexicon)
  (serialize-lexicon (hmm-token-lexicon hmm) s :hmm-token-lexicon)
  (serialize-hmm-transitions hmm s)
  (serialize-hmm-emissions hmm s)
  (serialize-hmm-trigram-table hmm s)
  (serialize-hmm-unigram-table hmm s)
  (serialize-hmm-parameters hmm s))

(defun serialize-hmm-model-to-file (hmm file &key (if-exists :supersede))
  (with-open-file (s file :direction :output :if-exists if-exists)
    (serialize-hmm-model hmm s)))

;; Deserialization
(defun deserialize-hmm-header (hmm header)
  (let ((tokens (cl-ppcre:all-matches-as-strings "\\S+" header)))
    (unless (equalp (subseq tokens 0 2) '("hmm" "header"))
      (error "HMM model can not be deserialized"))
    (let* ((header (list-to-plist (rest (rest tokens))))
           (n (parse-integer (getf header :n)))
           (token-count (parse-integer (getf header :token-count))))
      (setf (hmm-n hmm) n)
      (setf (hmm-token-count hmm) token-count))
    hmm))

(defun deserialize-hmm-transitions (hmm s)
  (let ((transitions (make-array (list (hmm-tag-cardinality hmm) (hmm-tag-cardinality hmm)) :initial-element nil)))
    (unless (equalp (read-line s nil nil)
                    "hmm transitions start")
      (error "HMM model transition table can not be deserialized"))
    (loop for line = (read-line s nil nil)
          until (equalp (string-trim *whitespace* line) "hmm transitions end")

          when (null line)
          do (error "Premature end of file")

          do (destructuring-bind (i j value)
                 (cl-ppcre:all-matches-as-strings "\\S+" (string-trim *whitespace* line))
               (setf (aref transitions
                           (parse-integer i)
                           (parse-integer j))
                     (read-from-string value))))
    transitions))

(defun deserialize-hmm-emissions (hmm s)
  (let ((emissions (make-array (hmm-tag-cardinality hmm) :initial-element nil)))
    (unless (equalp (read-line s nil nil)
                    "hmm emissions start")
      (error "HMM model emission table can not be deserialized"))
    (loop for i from 0 to (- (hmm-tag-cardinality hmm) 1)
          do (setf (aref emissions i) (make-hash-table)))
    (loop for line = (read-line s nil nil)
          until (equalp (string-trim *whitespace* line) "hmm emissions end")

          when (null line)
          do (error "Premature end of file")

          do (destructuring-bind (i j value)
                 (cl-ppcre:all-matches-as-strings "\\S+" (string-trim *whitespace* line))
               (let* ((i (parse-integer i))
                      (j (if (equalp j "unk") ;; may be :unk
                           :unk
                           (read-from-string j)))
                      (value (read-from-string value)))
                 (setf (gethash j (aref emissions i)) value))))
    emissions))

(defun deserialize-hmm-trigram-table (hmm s)
  (let ((trigram-table (make-array (list (hmm-tag-cardinality hmm)
                                         (hmm-tag-cardinality hmm)
                                         (hmm-tag-cardinality hmm))
                                   :initial-element nil)))
    (unless (equalp (read-line s nil nil)
                    "hmm trigram table start")
      (error "HMM model trigram table can not be deserialized"))
    (loop for line = (read-line s nil nil)
          until (equalp (string-trim *whitespace* line) "hmm trigram table end")

          when (null line)
          do (error "Premature end of file")

          do (destructuring-bind (i j k value)
                 (cl-ppcre:all-matches-as-strings "\\S+" (string-trim *whitespace* line))
               (setf (aref trigram-table
                           (parse-integer i)
                           (parse-integer j)
                           (parse-integer k))
                     (read-from-string value))))
    trigram-table))

(defun deserialize-hmm-unigram-table (hmm s)
  (let ((unigram-table (make-array (hmm-tag-cardinality hmm) :initial-element nil)))
    (unless (equalp (read-line s nil nil)
                    "hmm unigram table start")
      (error "HMM model unigram table can not be deserialized"))
    (loop for line = (read-line s nil nil)
          until (equalp (string-trim *whitespace* line) "hmm unigram table end")

          when (null line)
          do (error "Premature end of file")

          do (destructuring-bind (i value)
                 (cl-ppcre:all-matches-as-strings "\\S+" (string-trim *whitespace* line))
               (setf (aref unigram-table
                           (parse-integer i))
                     (read-from-string value))))
    unigram-table))

(defun deserialize-hmm-parameters (s)
  (unless (equalp (read-line s nil nil)
                    "hmm parameters start")
      (error "HMM model unigram table can not be deserialized"))
  (loop for line = (read-line s nil nil)
          until (equalp (string-trim *whitespace* line) "hmm parameters end")

          when (null line)
          do (error "Premature end of file")

          collect (destructuring-bind (param value)
                      (cl-ppcre:all-matches-as-strings "\\S+" (string-trim *whitespace* line))
                    (list (intern (string-upcase param) :keyword)
                          (read-from-string value)))))

(defun deserialize-hmm-model (s)
  (with-standard-io-syntax
    (let ((*package* (find-package :mulm))
          (*read-eval* nil)
          (hmm (make-hmm)))
      (deserialize-hmm-header hmm (read-line s nil nil))
      (setup-hmm hmm (hmm-n hmm) t)
      (setf (hmm-tag-lexicon hmm)
            (second (deserialize-lexicon s :hmm-tag-lexicon)))
      (setf (hmm-token-lexicon hmm)
            (second (deserialize-lexicon s :hmm-token-lexicon)))
      (setf (hmm-transitions hmm)
            (deserialize-hmm-transitions hmm s))
      (setf (hmm-emissions hmm)
            (deserialize-hmm-emissions hmm s))
      (setf (hmm-trigram-table hmm)
            (deserialize-hmm-trigram-table hmm s))
      (setf (hmm-unigram-table hmm)
            (deserialize-hmm-unigram-table hmm s))

      (let ((param-alist (deserialize-hmm-parameters s)))
        (loop for param in (mapcar #'first param-alist)
              do (ecase param
                   (:lambda-1 (setf (hmm-lambda-1 hmm)
                                    (second (assoc :lambda-1 param-alist))))
                   (:lambda-2 (setf (hmm-lambda-2 hmm)
                                    (second (assoc :lambda-2 param-alist))))
                   (:lambda-3 (setf (hmm-lambda-3 hmm)
                                    (second (assoc :lambda-3 param-alist))))
                   (:theta (setf (hmm-theta hmm)
                                 (second (assoc :theta param-alist))))
                   (:bigram-d (setf (hmm-bigram-d hmm)
                                    (second (assoc :bigram-d param-alist))))
                   (:trigram-d (setf (hmm-trigram-d hmm)
                                     (second (assoc :trigram-d param-alist)))))))

      (setup-hmm-beam hmm)
      (build-suffix-tries hmm)
    
      hmm)))

(defun deserialize-hmm-model-from-file (file)
  (with-open-file (s file)
    (deserialize-hmm-model s)))

(defun hash-table-diff-msg (h1 h2 &key (msg "diff at"))
  (let ((keys (union (loop for k being the hash-keys of h1 collect k)
                     (loop for k being the hash-keys of h2 collect k))))
    (loop for k in keys
          for v1 = (gethash k h1)
          for v2 = (gethash k h2)
          when (not (= v1 v2))
          do (format t "~a ~a: ~a - ~a~%" msg k v1 v2))))

(defun hmm-model-diff (hmm1 hmm2)
  (when (/= (hmm-token-count hmm1) (hmm-token-count hmm2))
    (format t "Token count diff: ~a - ~a~%"
            (hmm-token-count hmm1) (hmm-token-count hmm2)))
  (when (/= (hmm-tag-cardinality hmm1) (hmm-tag-cardinality hmm2))
    (format t "n diff: ~a - ~a~%"
           (hmm-tag-cardinality hmm1) (hmm-tag-cardinality hmm2)))
  (when (/= (hmm-lambda-1 hmm1) (hmm-lambda-1 hmm2))
    (format t "Lambda-1 diff: ~a - ~a~%"
            (hmm-lambda-1 hmm1) (hmm-lambda-1 hmm2)))
  (when (/= (hmm-lambda-2 hmm1) (hmm-lambda-2 hmm2))
    (format t "Lambda-2 diff: ~a - ~a~%"
            (hmm-lambda-2 hmm1) (hmm-lambda-2 hmm2)))
  (when (/= (hmm-lambda-3 hmm1) (hmm-lambda-3 hmm2))
    (format t "Lambda-3 diff: ~a - ~a~%"
            (hmm-lambda-3 hmm1) (hmm-lambda-3 hmm2)))
  (when (/= (hmm-theta hmm1) (hmm-theta hmm2))
    (format t "Theta diff: ~a - ~a~%"
            (hmm-theta hmm1) (hmm-theta hmm2)))
  (when (/= (hmm-bigram-d hmm1) (hmm-bigram-d hmm2))
    (format t "Bigram-d diff: ~a - ~a~%"
            (hmm-bigram-d hmm1) (hmm-bigram-d hmm2)))
  (when (/= (hmm-trigram-d hmm1) (hmm-trigram-d hmm2))
    (format t "Bigram-d diff: ~a - ~a~%"
            (hmm-trigram-d hmm1) (hmm-trigram-d hmm2)))
  
  (lexicon-diff (hmm-tag-lexicon hmm1) (hmm-tag-lexicon hmm2))
  (lexicon-diff (hmm-token-lexicon hmm1) (hmm-token-lexicon hmm2))

  (loop for i from 0 below (hmm-tag-cardinality hmm1)
        do (loop for j below (hmm-tag-cardinality hmm1)
                 for v1 = (aref (hmm-transitions hmm1) i j)
                 for v2 = (aref (hmm-transitions hmm2) i j)
                 when (and (not (and (null v1) (null v2)))
                           (/= v1 v2))
                 do (format t "Transitions diff at ~a ~a: ~a - ~a~%" i j v1 v2)))

  (when (not (equal (array-dimensions (hmm-emissions hmm1)) (array-dimensions (hmm-emissions hmm2))))
             (format t "Emissions diff array inconsistency: ~a - ~a~%"
                     (array-dimensions (hmm-emissions hmm1)) (array-dimensions (hmm-emissions hmm2))))
  
  (loop for i from 0
        for map1 across (hmm-emissions hmm1)
        for map2 across (hmm-emissions hmm2)
        do (when (/= (hash-table-count map1) (hash-table-count map2))
             (format t "Emissions diff hash table inconsistency at ~a~%" i))
        do (hash-table-diff-msg map1 map2 :msg (format nil "emissions diff for ~a" i)))

  (loop for i from 0 below (hmm-tag-cardinality hmm1)
        do (loop for j from 0 below (hmm-tag-cardinality hmm1)
                 do (loop for k from 0 below (hmm-tag-cardinality hmm1)
                          for v1 = (aref (hmm-trigram-table hmm1) i j k)
                          for v2 = (aref (hmm-trigram-table hmm2) i j k)
                          when (and (not (and (null v1) (null v2)))
                                    (/= v1 v2))
                          do (format t "Trigram table diff at ~a ~a ~a: ~a - ~a~%" i j k v1 v2))))

  (loop for i from 0 below (hmm-tag-cardinality hmm1)
        for v1 = (aref (hmm-unigram-table hmm1) i)
        for v2 = (aref (hmm-unigram-table hmm2) i)
        when (and (not (and (null v1) (null v2)))
                  (/= v1 v2))
        do (format t "Unigram table diff at ~a: ~a - ~a~%" i v1 v2)))
