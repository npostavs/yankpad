;;; yankpad.el --- Paste snippets from an org-mode file

;; Copyright (C) 2016 Erik Sjöstrand
;; MIT License

;; Author: Erik Sjöstrand
;; URL: http://github.com/Kungsgeten/yankpad
;; Version: 1.40
;; Keywords: abbrev convenience
;; Package-Requires: ()

;;; Commentary:

;; A way to insert text snippets from an org-mode file.  The org-mode file in
;; question is defined in `yankpad-file' and is set to "yankpad.org" in your
;; `org-directory' by default.  In this file, each heading specifies a snippet
;; category and each subheading of that category defines a snippet.  This way
;; you can have different yankpads for different occasions.
;;
;; If you have yasnippet installed, yankpad will try to use it when pasting
;; snippets.  This means that you can use the features that yasnippet provides
;; (tab stops, elisp, etc).  You can use yankpad without yasnippet, and then the
;; snippet will simply be inserted as is.
;;
;; You can also add keybindings to snippets, by setting an `org-mode' tag on the
;; snippet.  The last tag will be interpreted as a keybinding, and the snippet
;; can be run by using `yankpad-map' followed by the key.  `yankpad-map' is not
;; bound to any key by default.
;;
;; Another functionality is that snippets can include function calls, instead of
;; text.  In order to do this, the snippet heading should have a tag named
;; "func".  The snippet name could either be the name of the elisp function that
;; should be executed (will be called without arguments), or the content of the
;; snippet could be an `org-mode' src-block, which will then be executed when
;; you use the snippet.
;;
;; If you name a category to a major-mode name, that category will be switched
;; to when you change major-mode.  If you have projectile installed, you can also
;; name a categories to the same name as your projecile projects, and they will
;; be switched to when using `projectile-find-file'.
;;
;; To insert a snippet from the yankpad, use `yankpad-insert' or
;; `yankpad-expand'.  `yankpad-expand' will look for a keyword at point, and
;; expand a snippet with a name starting with that word, followed by
;; `yankpad-expand-separator' (a colon by default).  If you need to change the
;; category, use `yankpad-set-category'.
;;
;; For further customization, please see the Github page: https://github.com/Kungsgeten/yankpad
;; 
;; Here's an example of what yankpad.org could look like:

;;; Yankpad example:

;; ** Snippet 1
;;
;;    This is a snippet.
;;
;; ** snip2: Snippet 2
;;
;;    This is another snippet.  This snippet can be expanded by first typing "snip2" and
;;    then executing the `yankpad-expand' command.
;;    \* Org-mode doesn't like lines beginning with *
;;    Typing \* at the beginning of a line will be replaced with *
;; 
;;    If yanking a snippet into org-mode, this will respect the
;;    current tree level by default.  Set the variable
;;    `yankpad-respect-current-org-level' to nil in order to change that.
;;
;; * Category 2
;; ** Snippet 1
;;
;;    This is yet another snippet, in a different category.
;; ** Snippet 2        :s:
;;
;;    This snippet will be bound to "s" when using `yankpad-map'.  Let's say you
;;    bind `yankpad-map' to f7, you can now press "f7 s" to insert this snippet.
;;
;; ** magit-status          :func:
;; ** Run magit-status      :func:m:
;;    #+BEGIN_SRC emacs-lisp
;;    (magit-status)
;;    #+END_SRC
;;
;;; Code:

(require 'org-element)
(when (version< (org-version) "8.3")
  (require 'ox))

(defvar yankpad-file (expand-file-name "yankpad.org" org-directory)
  "The path to your yankpad.")

(defvar yankpad-category nil
  "The current yankpad category.  Change with `yankpad-set-category'.")
(put 'yankpad-category 'safe-local-variable #'string-or-null-p)

(defvar yankpad-category-heading-level 1
  "The `org-mode' heading level of categories in the `yankpad-file'.")

(defvar yankpad-snippet-heading-level 2
  "The `org-mode' heading level of snippets in the `yankpad-file'.")

(defvar yankpad-respect-current-org-level t
  "Whether to respect `org-current-level' when using \* in snippets and yanking them into `org-mode' buffers.")

(defvar yankpad-switched-category-hook nil
  "Hooks run after changing `yankpad-category'.")

(defvar yankpad-expand-separator ":"
  "String used to separate a keyword, at the start of a snippet name, from the title.  Used for `yankpad-expand'.")

(defvar yankpad--active-snippets nil
  "A cached version of the snippets in the current category.")

(defun yankpad-active-snippets ()
  "Get the snippets in the current category."
  (if yankpad--active-snippets
      yankpad--active-snippets
    (yankpad-set-active-snippets)))

(defun yankpad-set-category ()
  "Change the yankpad category."
  (interactive)
  (setq yankpad-category
        (completing-read "Category: " (yankpad--categories)))
  (run-hooks 'yankpad-switched-category-hook))

(defun yankpad-set-local-category (category)
  "Set `yankpad-category' to CATEGORY locally."
  (set (make-local-variable 'yankpad-category) category)
  (set (make-local-variable 'yankpad--active-snippets) nil)
  (run-hooks 'yankpad-switched-category-hook))

(defun yankpad-set-active-snippets ()
  "Set the `yankpad-active-snippets' to the snippets in the active category.
If no active category, call `yankpad-set-category'."
  (if yankpad-category
      (setq yankpad--active-snippets (yankpad--snippets yankpad-category))
    (yankpad-set-category)
    (yankpad-set-active-snippets)))

(defun yankpad-remove-active-snippets ()
  "Remove all entries in `yankpad--active-snippets`."
  (setq yankpad--active-snippets nil))

(add-hook 'yankpad-switched-category-hook #'yankpad-remove-active-snippets)

;;;###autoload
(defun yankpad-insert ()
  "Insert an entry from the yankpad.
Uses `yankpad-category', and prompts for it if it isn't set."
  (interactive)
  (unless yankpad-category
    (or (yankpad-local-category-to-major-mode)
        (yankpad-set-category)))
  (yankpad-insert-from-current-category))

(defun yankpad--insert-snippet-text (text indent)
  "Insert TEXT into buffer.  INDENT is whether/how to indent the snippet.
Use yasnippet and `yas-indent-line' if available."
  (setq text (substring-no-properties text 0 -1))
  (if (and (require 'yasnippet nil t)
           yas-minor-mode)
      (if (region-active-p)
          (yas-expand-snippet text (region-beginning) (region-end) `((yas-indent-line (quote ,indent))))
        (yas-expand-snippet text nil nil `((yas-indent-line (quote ,indent)))))
    (let ((start (point)))
      (insert text)
      (when indent
        (indent-region start (point))))))

(defun yankpad--trigger-snippet-function (snippetname content)
  "SNIPPETNAME can be an elisp function, without arguments, if CONTENT is nil.
If non-nil, CONTENT should hold a single `org-mode' src-block, to be executed.
Return the result of the function output as a string."
  (if (car content)
      (with-temp-buffer
        (delay-mode-hooks
          (org-mode)
          (insert (car content))
          (goto-char (point-min))
          (if (org-in-src-block-p)
              (prin1-to-string (org-babel-execute-src-block))
            (error "No org-mode src-block at start of snippet"))))
    (if (intern-soft snippetname)
        (prin1-to-string (funcall (intern-soft snippetname)))
      (error (concat "\"" snippetname "\" isn't a function")))))

(defun yankpad--run-snippet (snippet)
  "Triggers the SNIPPET behaviour."
  (let ((name (car snippet))
        (tags (cadr snippet))
        (content (cddr snippet)))
    (cond
     ((member "func" tags)
      (yankpad--trigger-snippet-function name content))
     ((member "results" tags)
      (insert (yankpad--trigger-snippet-function name content)))
     (t
      (if (car content)
          ;; Respect the tree levl when yanking org-mode headings.
          (let ((prepend-asterisks 1)
                (indent (cond ((member "indent_nil" tags)
                               nil)
                              ((member "indent_fixed" tags)
                               'fixed)
                              ((member "indent_auto" tags)
                               'auto)
                              ((and (require 'yasnippet nil t) yas-minor-mode)
                               yas-indent-line)
                              (t t))))
            (when (and yankpad-respect-current-org-level
                       (equal major-mode 'org-mode)
                       (org-current-level))
              (setq prepend-asterisks (org-current-level)))
            (yankpad--insert-snippet-text
             (replace-regexp-in-string
              "^\\\\[*]" (make-string prepend-asterisks ?*) (car content))
             indent))
        (message (concat "\"" name "\" snippet doesn't contain any text. Check your yankpad file.")))))))

(defun yankpad-insert-from-current-category (&optional name)
  "Insert snippet NAME from `yankpad-category'.  Prompts for NAME unless set.
Does not change `yankpad-category'."
  (let ((snippets (yankpad-active-snippets)))
    (unless name
      (setq name (completing-read "Snippet: " snippets)))
    (let ((snippet (assoc name (yankpad-active-snippets))))
      (if snippet
          (yankpad--run-snippet snippet)
        (message (concat "No snippet named " name))
        nil))))

(defun yankpad-expand ()
  "Replace word at point with a snippet.
Only works if the word is found in the first matching group of `yankpad-expand-keyword-regex'."
  (interactive)
  (let* ((word (word-at-point))
         (bounds (bounds-of-thing-at-point 'word))
         (snippet-prefix (concat word yankpad-expand-separator)))
    (when (and word yankpad-category)
      (catch 'loop
        (mapc
         (lambda (snippet)
           (when (string-prefix-p snippet-prefix (car snippet))
             (delete-region (car bounds) (cdr bounds))
             (yankpad--run-snippet snippet)
             (throw 'loop snippet)))
         (yankpad-active-snippets))
        nil))))

(defun yankpad-edit ()
  "Open the yankpad file for editing."
  (interactive)
  (find-file yankpad-file))

(defun yankpad--file-elements ()
  "Run `org-element-parse-buffer' on the `yankpad-file'."
  (with-temp-buffer
    (delay-mode-hooks
      (org-mode)
      (insert-file-contents yankpad-file)
      (org-element-parse-buffer))))

(defun yankpad--categories ()
  "Get the yankpad categories as a list."
  (let ((data (yankpad--file-elements)))
    (org-element-map data 'headline
      (lambda (h)
        (when (equal (org-element-property :level h)
                     yankpad-category-heading-level)
          (org-element-property :raw-value h))))))

(defun yankpad--snippet-elements (category-name)
  "Get all the snippet `org-mode' heading elements in CATEGORY-NAME."
  (let ((data (yankpad--file-elements))
        (lineage-func (if (version< (org-version) "8.3")
                          #'org-export-get-genealogy
                        #'org-element-lineage)))
    (org-element-map data 'headline
      (lambda (h)
        (let ((lineage (funcall lineage-func h)))
          (when (and (equal (org-element-property :level h)
                            yankpad-snippet-heading-level)
                     (member category-name
                             (mapcar (lambda (x)
                                       (org-element-property :raw-value x))
                                     lineage)))
            h))))))

(defun yankpad--snippets (category-name)
  "Get an alist of the snippets in CATEGORY-NAME.
The car is the snippet name and the cdr is a cons (tags snippet-string)."
  (mapcar (lambda (h)
            (let ((heading (org-element-property :raw-value h))
                  (text (org-element-map h 'section #'org-element-interpret-data))
                  (tags (org-element-property :tags h)))
              (cons heading (cons tags text))))
          (yankpad--snippet-elements category-name)))

(defun yankpad-map ()
  "Create and execute a keymap out of the last tags of snippets in `yankpad-category'."
  (interactive)
  (define-prefix-command 'yankpad-keymap)
  (mapc (lambda (snippet)
          (let ((last-tag (car (last (cadr snippet)))))
            (when (and last-tag
                       (not (eq last-tag "func"))
                       (not (eq last-tag "results"))
                       (not (string-prefix-p "indent_" last-tag)))
              (let ((heading (car snippet))
                    (content (cddr snippet))
                    (tags (cadr  snippet)))
                (define-key yankpad-keymap (kbd (substring-no-properties last-tag))
                  `(lambda ()
                     (interactive)
                     (yankpad--run-snippet (cons ,heading
                                                 (cons (list ,@tags)
                                                       (list ,@content))))))))))
        (yankpad-active-snippets))
  (set-transient-map 'yankpad-keymap))

(defun yankpad-local-category-to-major-mode ()
  "Try to change `yankpad-category' to match the buffer's major mode.
If successful, make `yankpad-category' buffer-local."
  (when (file-exists-p yankpad-file)
    (let ((category (car (member (symbol-name major-mode)
                                 (yankpad--categories)))))
      (when category (yankpad-set-local-category category)))))

(add-hook 'after-change-major-mode-hook #'yankpad-local-category-to-major-mode)

(defun yankpad-local-category-to-projectile ()
  "Try to change `yankpad-category' to match the `projectile-project-name'.
If successful, make `yankpad-category' buffer-local."
  (when (and (require 'projectile nil t)
             (file-exists-p yankpad-file))
    (let ((category (car (member (projectile-project-name)
                                 (yankpad--categories)))))
      (when category (yankpad-set-local-category category)))))

(eval-after-load "projectile"
  (add-hook 'projectile-find-file-hook #'yankpad-local-category-to-projectile))

(provide 'yankpad)
;;; yankpad.el ends here
