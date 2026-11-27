; Comments
(comment) @comment

; Literals
(string) @string
(number) @number
; (boolean) @boolean
(null) @constant.builtin

; Identifiers
(identifier) @variable

; Function definitions and calls
(function_definition
  fn: (fn) @keyword
  name: (identifier) @function)

(call
  function: (identifier) @function.call)

; Key/value pairs
(pair
  key: (identifier) @property)

(pair
  name: (value_ref) @variable)

(pair
  key: (identifier)
  enum_value: (identifier) @constant.enum)

; References
(value_ref
  "#" @punctuation.special
  name: (identifier) @variable)

(naked_value_ref) @variable

(keyref) @variable

(keyref_path) @variable

(access_type
  ":" @punctuation.delimiter
  name: (identifier) @property)


; Operators
(binary_expression
  operator: ["+" "-" "*" "/" ">" "<" ">=" "<="] @operator)

(unary_expression
  operator: ["-" "+"] @operator)

; Parentheses and delimiters
["(" ")" "{" "}"] @punctuation.bracket

; Commas
"," @punctuation.delimiter

; Assignment
"=" @operator

; Special symbols
"#" @punctuation.special
"!" @punctuation.special

