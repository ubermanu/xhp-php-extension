/*
  +----------------------------------------------------------------------+
  | XHP                                                                  |
  +----------------------------------------------------------------------+
  | Copyright (c) 1998-2014 Zend Technologies Ltd. (http://www.zend.com) |
  | Copyright (c) 2009-2014 Facebook, Inc. (http://www.facebook.com)     |
  +----------------------------------------------------------------------+
  | This source file is subject to version 2.00 of the Zend license,     |
  | that is bundled with this package in the file LICENSE.ZEND, and is   |
  | available through the world-wide-web at the following url:           |
  | http://www.zend.com/license/2_00.txt.                                |
  | If you did not receive a copy of the Zend license and are unable to  |
  | obtain it through the world-wide-web, please send a note to          |
  | license@zend.com so we can mail you a copy immediately.              |
  +----------------------------------------------------------------------+
*/

%{ /* -*- mode: c++ -*- */
#include "xhp.hpp"
#include <string.h>

// A PHP file is made of multiple languages, each with its own lexing rules.
// The starting mode or state is the HTML state, then comes the PHP state, 
// and with XHP there is even an XHP state. Certain tokens indicate a 
// transition from one state to another and the macros below are used to 
// manage this state.
#define push_state(s) xhp_new_push_state(s, yyg)
#define pop_state() xhp_new_pop_state(yyg)
#define set_state(s) xhp_set_state(s, yyg)

// This is used to help contextual lexing. For instance 'attribute' is
// considered a XHP keyword after a '{' of a class definition, 
// but a regular identifier in other contexts.
#define last_token() yyextra->last_token

#define YY_USER_ACTION \
  if (yyextra->terminated) \
    return 0; \
  if (!yyg->yy_more_len) \
    yyextra->first_lineno = yyextra->lineno;

#define tok_consume() \
  *yylval = code_rope(code_rope::_rope_t(yytext, yyleng), yyextra->first_lineno, yyextra->lineno - yyextra->first_lineno)

#define tok_return(t) \
  if (shouldReturnToken(t, yyextra->return_all_tokens)) \
    return yy_token(t, yyg)

#define tok(t) \
  *yylval = code_rope(code_rope::_rope_t(yytext, yyleng), yyextra->first_lineno, yyextra->lineno - yyextra->first_lineno); \
  if (shouldReturnToken(t, yyextra->return_all_tokens)) \
    return yy_token(t, yyg)

#define YY_USER_INIT \
  if (yyextra->insert_token) { \
    yyg->yy_init = 0; \
    int ft = yyextra->insert_token; \
    yyextra->insert_token = 0; \
    return yy_token(ft, yyg); \
  }

#define IS_LABEL_START(c) (((c) >= 'a' && (c) <= 'z') || ((c) >= 'A' && (c) <= 'Z') || (c) == '_' || (c) >= 0x7F)
#define IS_LABEL_SUCCESSOR(c) (((c) >= 'a' && (c) <= 'z') || ((c) >= 'A' && (c) <= 'Z') || ((c) >= '0' && (c) <= '9') || (c) == '_' || (c) >= 0x80)

using namespace std;

const char* yytokname(int tok);
static int yy_token(int tok, struct yyguts_t* yyg);
static void yy_scan_newlines(const char* text, size_t len, struct yyguts_t* yyg);

/**
 * "Next token types" tell us how to interpret the next characters in the
 * input stream based on the previous token for the purpose of recognizing
 * XHP tags, XHP class names, XHP category names, type lists, and lambda
 * expressions.
 *   XhpTag:
 *     "<"[a-zA-Z_\x7f-\xff] will be treated as the start of an XHP tag
 *   XhpTagMaybe:
 *     "<"[a-zA-Z_\x7f-\xff] will be treated as possibly being the start of an
 *     XHP tag; we will scan ahead looking at subsequent characters to figure
 *     out if "<" is definitely the start of an XHP tag
 *   XhpClassName:
 *     ":"{XHPLABEL} will be treated as an XHP class name
 *   XhpCategoryName:
 *     "%"{XHPLABEL} will be treated as an XHP category name
 */
namespace NextTokenType {
  static const int Normal = 0x1;
  static const int XhpTag = 0x2;
  static const int XhpTagMaybe = 0x4;
  static const int XhpClassName = 0x8;
  static const int XhpCategoryName = 0x10;
}

static int getNextTokenType(int t) {
  switch (t) {
    case '=': case '.': case '+': case '-': case '*': case '/': case '%':
    case '!': case '~': case '&': case '^': case '<': case '>': case '?':
    case ':': case '[': case '{': case ';': case '@': case -1:
    case T_LOGICAL_OR:
    case T_LOGICAL_XOR:
    case T_LOGICAL_AND:
    case T_SL:
    case T_SR:
    case T_BOOLEAN_OR:
    case T_BOOLEAN_AND:
    case T_IS_EQUAL:
    case T_IS_NOT_EQUAL:
    case T_IS_IDENTICAL:
    case T_IS_NOT_IDENTICAL:
    case T_IS_SMALLER_OR_EQUAL:
    case T_IS_GREATER_OR_EQUAL:
    case T_SPACESHIP:
    case T_PLUS_EQUAL:
    case T_MINUS_EQUAL:
    case T_MUL_EQUAL:
    case T_DIV_EQUAL:
    case T_CONCAT_EQUAL:
    case T_MOD_EQUAL:
    case T_AND_EQUAL:
    case T_OR_EQUAL:
    case T_XOR_EQUAL:
    case T_SL_EQUAL:
    case T_SR_EQUAL:
    case T_ECHO:
    case T_PRINT:
    case T_CLONE:
    case T_EXIT:
    case T_RETURN:
    case T_YIELD:
    case T_YIELD_FROM:
    case T_NEW:
    case T_INSTANCEOF:
    case T_DOUBLE_ARROW:
    case T_NS_SEPARATOR:
    case T_INLINE_HTML:
    case T_INT_CAST:
    case T_DOUBLE_CAST:
    case T_STRING_CAST:
    case T_ARRAY_CAST:
    case T_OBJECT_CAST:
    case T_BOOL_CAST:
    case T_UNSET_CAST:
    case T_UNRESOLVED_LT:
    case T_AS:
      return NextTokenType::XhpTag |
             NextTokenType::XhpClassName;
    case ',': case '(': case '|': case T_UNRESOLVED_OP:
      return NextTokenType::XhpTag |
             NextTokenType::XhpClassName |
             NextTokenType::XhpCategoryName;
    case '}':
    case T_OPEN_TAG:
      return NextTokenType::XhpTagMaybe |
             NextTokenType::XhpClassName;
    case T_INC:
    case T_DEC:
      return NextTokenType::XhpTagMaybe;
    case T_EXTENDS:
    case T_CLASS:
    case T_PRIVATE:
    case T_PROTECTED:
    case T_PUBLIC:
    case T_STATIC:
      return NextTokenType::XhpClassName;
    case T_OBJECT_OPERATOR:
    case T_STRING:
    case T_XHP_CHILDREN:
    case T_XHP_REQUIRED:
    case T_XHP_ENUM:
    case T_ARRAY:
    case T_XHP_ATTRIBUTE:
      return NextTokenType::XhpClassName;
    case T_XHP_CATEGORY:
      return NextTokenType::XhpCategoryName;
    default:
      return NextTokenType::Normal;
  }
}

static bool shouldReturnToken(int t, bool force)
{
    if (!force) {
        switch (t) {
          case T_DOC_COMMENT:
          case T_COMMENT:
          case T_WHITESPACE:
            return false;
        }
    }
    return true;
}

static void strip_underscores(char *str, size_t *len)
{
  char *src = str, *dest = str;
  while (*src != '\0') {
    if (*src != '_') {
      *dest = *src;
      dest++;
    } else {
      --(*len);
    }
    src++;
  }
  *dest = '\0';
}

%}

 /* The different lexing states. Note that the transitions are done either
  * in the lex actions, or in a generic manner in yy_token(). */
%x ST_PHP
%x ST_PHP_COMMENT
%x ST_PHP_EOL_COMMENT
%x ST_PHP_DOC_COMMENT
%x ST_PHP_HEREDOC_START
%x ST_PHP_HEREDOC_NSTART
%x ST_PHP_HEREDOC
%x ST_PHP_HEREDOC_END
%x ST_PHP_NO_RESERVED_WORDS
%x ST_XHP_IN_TAG
%x ST_XHP_CHILD
%x ST_XHP_ATTR_TYPE_DECL
%x ST_XHP_CHILDREN_DECL
%x ST_XHP_COMMENT
%x ST_XHP_END_SINGLETON_TAG
%x ST_LT_CHECK
%x ST_LOOKING_FOR_COLON
%x ST_XHP_END_CLOSE_TAG
%x ST_BACKQUOTE
%x ST_DOUBLE_QUOTES
%x ST_LOOKING_FOR_PROPERTY
%x ST_LOOKING_FOR_XHP_ATTRIBUTE
%x ST_LOOKING_FOR_VARNAME
%x ST_VAR_OFFSET

%option prefix="xhp"
%option reentrant
 /* PHP allows IF or if */
%option case-insensitive
%option noyywrap nodefault
%option stack
%option bison-bridge
%option 8bit

 /* I think an interactive scanner is required because of the bison state 
  * pushing we do. I'm putting an explicit interactive declaration here in case
  * someone tries adding -CF or whatever to the make flags. */
%option interactive

 /* to get a Flex debug trace, uncomment %option debug, and uncomment
  *
  * %option debug
  */

 /* Definitions (Substitutions) */

LNUM [0-9]+(_[0-9]+)*
DNUM ({LNUM}?"."{LNUM})|({LNUM}"."{LNUM}?)
EXPONENT_DNUM (({LNUM}|{DNUM})[eE][+-]?{LNUM})
HNUM "0x"[0-9a-fA-F]+(_[0-9a-fA-F]+)*
BNUM "0b"[01]+(_[01]+)*
ONUM "0o"[0-7]+(_[0-7]+)*
LABEL_START [a-zA-Z_\x7f-\xff]
LABEL {LABEL_START}[a-zA-Z0-9_\x7f-\xff]*
ANY_CHAR (.|[\n])
WHITESPACE [ \n\r\t]+
TOKENS [;:,.\[\])|^&+\-*/=%!~$<>?@]
TABS_AND_SPACES [ \t]*
NEWLINE ("\r\n"|"\n"|"\r")
XHPLABEL {LABEL}([:-]{LABEL})*
COMMENT_REGEX ("/*"([^\*]|("*"[^/]))*"*/"|("//"|"#")[^\r\n]*{NEWLINE})
WHITESPACE_AND_COMMENTS ([ \n\r\t]|({COMMENT_REGEX}))+

/*
 * LITERAL_DOLLAR matches unescaped $ that aren't followed by a label character
 * or a { and therefore will be taken literally. The case of literal $ before
 * a variable or "${" is handled in a rule for each string type
 */
DOUBLE_QUOTES_LITERAL_DOLLAR ("$"+([^a-zA-Z_\x7f-\xff$\"\\{]|("\\"{ANY_CHAR})))
BACKQUOTE_LITERAL_DOLLAR     ("$"+([^a-zA-Z_\x7f-\xff$`\\{]|("\\"{ANY_CHAR})))
/*
 * CHARS matches everything up to a variable or "{$"
 * {'s are matched as long as they aren't followed by a $
 * The case of { before "{$" is handled in a rule for each string type
 *
 * For heredocs, matching continues across/after newlines if/when it's known
 * that the next line doesn't contain a possible ending label
 */
DOUBLE_QUOTES_CHARS ("{"*([^$\"\\{]|("\\"{ANY_CHAR}))|{DOUBLE_QUOTES_LITERAL_DOLLAR})
BACKQUOTE_CHARS     ("{"*([^$`\\{]|("\\"{ANY_CHAR}))|{BACKQUOTE_LITERAL_DOLLAR})

%%

<ST_XHP_ATTR_TYPE_DECL>{
  "bool"     tok(T_XHP_BOOLEAN);
  "int"      tok(T_XHP_NUMBER);
  "float"    tok(T_XHP_FLOAT);
  "callable" tok(T_CALLABLE);
  "var"      tok(T_VAR);
  "mixed"    tok(T_XHP_MIXED);
  "array"    tok(T_ARRAY);
  "string"   tok(T_XHP_STRING);
  "("        tok('(');
  ":"        tok(T_XHP_COLON);
  ">>" {
    yyless(1);
    tok(T_TYPELIST_GT);
  }
  ">" tok(T_TYPELIST_GT);
  "<" tok(T_TYPELIST_LT);
  ";" { pop_state(); tok(';'); }
  "enum"     tok(T_XHP_ENUM);
  "@required"  tok(T_XHP_REQUIRED);
}

<ST_XHP_CHILDREN_DECL>{
  any tok(T_XHP_ANY);
  pcdata tok(T_XHP_PCDATA);
  empty tok(T_EMPTY);
  {LABEL} tok(T_STRING);
  ";" {
    pop_state();
    tok(';');
  }
}

 /* Open / close PHP + inline HTML */
<INITIAL>{
  "<?php"([ \t]|{NEWLINE}) {
    yy_scan_newlines(yytext + 5, yyleng - 5, yyg);
    // the state transition will be done in yy_token()
    tok(T_OPEN_TAG);
  }
  "<?" {
    if (yyextra->short_tags) {
      tok(T_OPEN_TAG);
    } else {
      tok(T_INLINE_HTML);
    }
  }
  "<?=" {
    if (yyextra->short_tags) {
      tok(T_OPEN_TAG_WITH_ECHO);
    } else {
      tok(T_INLINE_HTML);
    }
  }
  "<"|[^<]* {
    yy_scan_newlines(yytext, yyleng, yyg);
    tok(T_INLINE_HTML);
  }
}
<ST_PHP,ST_PHP_NO_RESERVED_WORDS>{
  "?>"{NEWLINE}? {
    yy_scan_newlines(yytext + 2, yyleng - 2, yyg);
    tok(T_CLOSE_TAG);
  }
}

 /* Comments and whitespace */
<ST_PHP,ST_PHP_NO_RESERVED_WORDS,ST_XHP_CHILDREN_DECL,ST_XHP_ATTR_TYPE_DECL,ST_XHP_IN_TAG>{
  "#"|"//" {
    push_state(ST_PHP_EOL_COMMENT);
    yymore();
  }
  "/**"{WHITESPACE} {
    yy_scan_newlines(yytext + 3, yyleng - 3, yyg);
    push_state(ST_PHP_DOC_COMMENT);
    yymore();
  }
  "/*" {
    push_state(ST_PHP_COMMENT);
    yymore();
  }
  {WHITESPACE}+ { yy_scan_newlines(yytext, yyleng, yyg); tok(T_WHITESPACE); }
}
<ST_PHP_EOL_COMMENT>{
  {NEWLINE} {
    yyless(yyleng - 1);
    pop_state();
    tok(T_COMMENT);
  }
  [^\r\n?]+ yymore();
  "?>" {
    yyless(yyleng - 2);
    pop_state();
    tok(T_COMMENT);
  }
  . yymore();
  <<EOF>> {
    yyless(yyleng - 1);
    pop_state();
    tok(T_COMMENT);
  }
}
<ST_PHP_DOC_COMMENT,ST_PHP_COMMENT>{
  {NEWLINE} {
    ++yyextra->lineno;
    yymore();
  }
  [^*\r\n]+|"*" yymore();
}
<ST_PHP_DOC_COMMENT>"*/" {
  if (!yyextra->return_all_tokens) {
    // If we're tokenizing, the emitted token has the comment, so we don't need
    // to copy it over to the next token. Otherwise, the parser drops all
    // comments, so the definition of yy_token below will attach doc comments
    // to the next token so they survive.
    yyextra->doc_block = code_rope(yytext, yyextra->first_lineno, yyextra->lineno - yyextra->first_lineno);
    yyextra->has_doc_block = true;
  }
  pop_state();
  tok(T_DOC_COMMENT);
}
<ST_PHP_COMMENT>"*/" {
  pop_state();
  tok(T_COMMENT);
}

 /* Reserved words */
<ST_PHP>{
  include tok(T_INCLUDE);
  include_once tok(T_INCLUDE_ONCE);
  eval tok(T_EVAL);
  require tok(T_REQUIRE);
  require_once tok(T_REQUIRE_ONCE);
  or tok(T_LOGICAL_OR);
  xor tok(T_LOGICAL_XOR);
  and tok(T_LOGICAL_AND);
  print tok(T_PRINT);
  instanceof tok(T_INSTANCEOF);
  new tok(T_NEW);
  clone tok(T_CLONE);
  exit tok(T_EXIT);
  die tok(T_EXIT);
  if tok(T_IF);
  elseif tok(T_ELSEIF);
  else tok(T_ELSE);
  endif tok(T_ENDIF);
  echo tok(T_ECHO);
  do tok(T_DO);
  while tok(T_WHILE);
  endwhile tok(T_ENDWHILE);
  for tok(T_FOR);
  endfor tok(T_ENDFOR);
  foreach tok(T_FOREACH);
  endforeach tok(T_ENDFOREACH);
  declare tok(T_DECLARE);
  enddeclare tok(T_ENDDECLARE);
  as tok(T_AS);
  switch tok(T_SWITCH);
  match tok(T_MATCH);
  endswitch tok(T_ENDSWITCH);
  case tok(T_CASE);
  default tok(T_DEFAULT);
  break tok(T_BREAK);
  continue tok(T_CONTINUE);
  goto tok(T_GOTO);
  fn tok(T_FN);
  function tok(T_FUNCTION);
  const tok(T_CONST);
  return tok(T_RETURN);
  try tok(T_TRY);
  catch tok(T_CATCH);
  finally tok(T_FINALLY);
  throw tok(T_THROW);
  use tok(T_USE);
  global tok(T_GLOBAL);
  static tok(T_STATIC);
  abstract tok(T_ABSTRACT);
  final tok(T_FINAL);
  private tok(T_PRIVATE);
  protected tok(T_PROTECTED);
  public tok(T_PUBLIC);
  readonly tok(T_READONLY);
  "readonly"[ \n\r\t]*"(" {
    yyless(strlen("readonly"));
    tok(T_STRING);
  }
  var tok(T_VAR);
  unset tok(T_UNSET);
  isset tok(T_ISSET);
  empty tok(T_EMPTY);
  __halt_compiler tok(T_HALT_COMPILER);
  class tok(T_CLASS);
  interface tok(T_INTERFACE);
  "enum"{WHITESPACE}("extends"|"implements") {
    yyless(4);
    tok(T_STRING);
  }
  "enum"{WHITESPACE}[a-zA-Z_\x80-\xff] {
    yyless(4);
    tok(T_ENUM);
  }
  extends tok(T_EXTENDS);
  implements tok(T_IMPLEMENTS);
  list tok(T_LIST);
  array tok(T_ARRAY);
  callable tok(T_CALLABLE);
  __class__ tok(T_CLASS_C);
  __method__ tok(T_METHOD_C);
  __function__ tok(T_FUNC_C);
  __line__ tok(T_LINE);
  __file__ tok(T_FILE);
  __trait__ tok(T_TRAIT_C);
  namespace tok(T_NAMESPACE);
  trait tok(T_TRAIT);
  insteadof tok(T_INSTEADOF);
  "yield"{WHITESPACE}"from" {
    yy_scan_newlines(yytext, yyleng, yyg);
    tok(T_YIELD_FROM);
  }
  "#[" tok(T_ATTRIBUTE);
  yield tok(T_YIELD);
  "..." tok(T_ELLIPSIS);
  __namespace__ tok(T_NS_C);
  __dir__ tok(T_DIR);
  (?-i:"attribute") {
    if ((last_token() == '{' || last_token() == '}' || last_token() == ';')) {
      push_state(ST_XHP_ATTR_TYPE_DECL);
      tok(T_XHP_ATTRIBUTE);
    } else {
      tok(T_STRING);
    }
  }
  (?-i:"category") {
    if ((last_token() == '{' || last_token() == '}' || last_token() == ';')) {
      tok(T_XHP_CATEGORY);
    } else {
      tok(T_STRING);
    }
  }
  (?-i:"children") {
    if ((last_token() == '{' || last_token() == '}' || last_token() == ';')) {
      push_state(ST_XHP_CHILDREN_DECL);
      tok(T_XHP_CHILDREN);
    } else {
      tok(T_STRING);
    }
  }
}

 /* Operators */
<ST_PHP,ST_PHP_NO_RESERVED_WORDS,ST_XHP_ATTR_TYPE_DECL,ST_XHP_CHILDREN_DECL>{
  "+=" tok(T_PLUS_EQUAL);
  "-=" tok(T_MINUS_EQUAL);
  "*=" tok(T_MUL_EQUAL);
  "**" tok(T_POW);
  "**=" tok(T_POW_EQUAL);
  "/=" tok(T_DIV_EQUAL);
  ".=" tok(T_CONCAT_EQUAL);
  "%=" tok(T_MOD_EQUAL);
  "&=" tok(T_AND_EQUAL);
  "|=" tok(T_OR_EQUAL);
  "^=" tok(T_XOR_EQUAL);
  "<<=" tok(T_SL_EQUAL);
  ">>=" tok(T_SR_EQUAL);
  "??=" tok(T_COALESCE_EQUAL);
  "||" tok(T_BOOLEAN_OR);
  "&&" tok(T_BOOLEAN_AND);
  "==" tok(T_IS_EQUAL);
  "!="|"<>" tok(T_IS_NOT_EQUAL);
  "===" tok(T_IS_IDENTICAL);
  "!==" tok(T_IS_NOT_IDENTICAL);
  "<=>" tok(T_SPACESHIP);
  "<=" tok(T_IS_SMALLER_OR_EQUAL);
  ">=" tok(T_IS_GREATER_OR_EQUAL);
  "<<" tok(T_SL);
  ">>" tok(T_SR);
  "++" tok(T_INC);
  "--" tok(T_DEC);
  "?->" {
    push_state(ST_LOOKING_FOR_PROPERTY);
    tok(T_NULLSAFE_OBJECT_OPERATOR);
  }
  "->" {
    push_state(ST_LOOKING_FOR_PROPERTY);
    tok(T_OBJECT_OPERATOR);
  }
  "=>" tok(T_DOUBLE_ARROW);
  "::" tok(T_PAAMAYIM_NEKUDOTAYIM);
  "??" tok(T_COALESCE);
  ":"{XHPLABEL} {
    int ntt = getNextTokenType(last_token());
    if (ntt & NextTokenType::XhpClassName) {
      yytext++; yyleng--; // skipping ":"
      tok(T_XHP_LABEL);
    }
    yyless(1);
    tok(':');
  }
  "%"{XHPLABEL} {
    int ntt = getNextTokenType(last_token());
    if (ntt & NextTokenType::XhpCategoryName) {
      yytext++; yyleng--; // skipping "%"
      tok(T_XHP_CATEGORY_LABEL);
    }
    yyless(1);
    tok('%');
  }
}

 /* Casts */
<ST_PHP,ST_PHP_NO_RESERVED_WORDS>{
  "("{TABS_AND_SPACES}(int|integer){TABS_AND_SPACES}")" tok(T_INT_CAST);
  "("{TABS_AND_SPACES}(real|double|float){TABS_AND_SPACES}")" tok(T_DOUBLE_CAST);
  "("{TABS_AND_SPACES}(string|binary){TABS_AND_SPACES}")" tok(T_STRING_CAST);
  "("{TABS_AND_SPACES}array{TABS_AND_SPACES}")" tok(T_ARRAY_CAST);
  "("{TABS_AND_SPACES}object{TABS_AND_SPACES}")" tok(T_OBJECT_CAST);
  "("{TABS_AND_SPACES}(bool|boolean){TABS_AND_SPACES}")" tok(T_BOOL_CAST);
  "("{TABS_AND_SPACES}unset{TABS_AND_SPACES}")" tok(T_UNSET_CAST);
}

 /* Numbers */
<ST_PHP,ST_PHP_NO_RESERVED_WORDS,ST_XHP_ATTR_TYPE_DECL,ST_XHP_IN_TAG>{
  {LNUM} {
    size_t len = yyleng;
    char *end, *lnum = yytext;
    bool is_octal = lnum[0] == '0';
    bool contains_underscores = (memchr(lnum, '_', len) != NULL);

    if (contains_underscores) {
      lnum = strndup(lnum, len);
      strip_underscores(lnum, &len);
    }

    errno = 0;
    strtoll(lnum, &end, is_octal ? 8 : 10);

    if (contains_underscores) {
      free(lnum);
    }

    if (!errno) {
      tok(T_LNUMBER);
    } else {
      tok(T_DNUMBER);
    }
  }
  {BNUM} {
    /* The +/- 2 skips "0b" */
    size_t len = yyleng - 2;
    char *bin = yytext + 2;
    bool contains_underscores;

    /* Skip any leading 0s */
    while (len > 0 && (*bin == '0' || *bin == '_')) {
      ++bin;
      --len;
    }

    contains_underscores = (memchr(bin, '_', len) != NULL);

    if (contains_underscores) {
      char *src = bin;
      while (*src != '\0') {
        if (*src == '_') {
          --len;
        }
        src++;
      }
    }

    if (len < 64) {
      tok(T_LNUMBER);
    } else {
      tok(T_DNUMBER);
    }
  }
  {ONUM} {
    /* The +/- 2 skips "0o" */
    size_t len = yyleng - 2;
    char *end, *octal = yytext + 2;
    bool contains_underscores;

    /* Skip any leading 0s */
    while (len > 0 && (*octal == '0' || *octal == '_')) {
      ++octal;
      --len;
    }

    contains_underscores = (memchr(octal, '_', len) != NULL);

    if (contains_underscores) {
      octal = strndup(octal, len);
      strip_underscores(octal, &len);
    }

    errno = 0;
    strtoll(octal, &end, 8);

    if (contains_underscores) {
      free(octal);
    }

    if (!errno) {
      // Octal fits into a long.
      tok(T_LNUMBER);
    } else {
      tok(T_DNUMBER);
    }
  }
  {HNUM} {
    /* The +/- 2 skips "0x" */
    size_t len = yyleng - 2;
    char *hex = yytext + 2;
    bool contains_underscores;

    /* Skip any leading 0s */
    while (len > 0 && (*hex == '0' || *hex == '_')) {
      ++hex;
      --len;
    }

    contains_underscores = (memchr(hex, '_', len) != NULL);

    if (contains_underscores) {
      char *src = hex;
      while (*src != '\0') {
        if (*src == '_') {
          --len;
        }
        src++;
      }
    }

    if (len < 16 || (len == 16 && *hex <= '7')) {
      tok(T_LNUMBER);
    } else {
      tok(T_DNUMBER);
    }
  }
  {DNUM}|{EXPONENT_DNUM} tok(T_DNUMBER);
}

<ST_PHP,ST_PHP_NO_RESERVED_WORDS,ST_XHP_ATTR_TYPE_DECL,ST_XHP_CHILDREN_DECL>{
  "namespace"("\\"{LABEL})+ {
    tok(T_NAME_RELATIVE);
  }
}

<ST_PHP,ST_PHP_NO_RESERVED_WORDS,ST_XHP_ATTR_TYPE_DECL,ST_XHP_CHILDREN_DECL>{
  {LABEL}("\\"{LABEL})+ {
    tok(T_NAME_QUALIFIED);
  }
}

<ST_PHP,ST_PHP_NO_RESERVED_WORDS,ST_XHP_ATTR_TYPE_DECL,ST_XHP_CHILDREN_DECL>{
  "\\"{LABEL}("\\"{LABEL})* {
    tok(T_NAME_FULLY_QUALIFIED);
  }
}

<ST_PHP,ST_PHP_NO_RESERVED_WORDS,ST_XHP_ATTR_TYPE_DECL,ST_XHP_CHILDREN_DECL>{
  "\\" tok(T_NS_SEPARATOR);
}

 /* Scalars (parsing these doesn't really matter since we just pass them through literally) */
 /*
  b?'(\\.|\\\n|[^\\']+)*'|b?\"(\\.|\\\n|[^\\\"]+)*\" {
    yy_scan_newlines(yytext, yyleng, yyg);
    tok(T_CONSTANT_ENCAPSED_STRING);
  }
  */
<ST_PHP,ST_PHP_NO_RESERVED_WORDS,ST_XHP_ATTR_TYPE_DECL>{
  {LABEL} tok(T_STRING);
  "$"{LABEL} tok(T_VARIABLE);
  (b?[\"]{DOUBLE_QUOTES_CHARS}*("{"*|"$"*)[\"]) {
    yy_scan_newlines(yytext, yyleng, yyg);
    tok(T_CONSTANT_ENCAPSED_STRING);
  }
  (b?[\']([^\'\\]|("\\"{ANY_CHAR}))*[\']?) {
    int closed = (yytext[yyleng - 1] == '\'');
    tok(closed ? T_CONSTANT_ENCAPSED_STRING : T_ENCAPSED_AND_WHITESPACE);
  }
  b?[\"] {
    int bprefix = (yytext[0] != '"') ? 1 : 0;
    push_state(ST_DOUBLE_QUOTES);
    tok('"');
  }
  ` {
    push_state(ST_BACKQUOTE);
    tok('`');
  }
}

<ST_PHP,ST_PHP_NO_RESERVED_WORDS>"&"[ \t\r\n]*("$"|"...") {
  yyless(1);
  tok(T_AMPERSAND_FOLLOWED_BY_VAR_OR_VARARG);
}

<ST_PHP,ST_PHP_NO_RESERVED_WORDS>"&" {
  tok(T_AMPERSAND_NOT_FOLLOWED_BY_VAR_OR_VARARG);
}

<ST_PHP>{TOKENS}   tok(yytext[0]);
<ST_PHP,ST_PHP_NO_RESERVED_WORDS>"{" {
  push_state(ST_PHP);
  tok('{');
}

<ST_PHP>"?"/":"[a-zA-Z_\x7f-\xff] {
  int ntt = getNextTokenType(last_token());
  if ((ntt & NextTokenType::XhpClassName) && last_token() != '}') {
    tok('?');
  }
  /* If XHP is enabled and "?:" occurs in a place where an XHP class name is
     not expected or it occurs after "}", drop into the ST_LOOKING_FOR_COLON
     state to avoid potentially treating ":" as the beginning of an XHP class
     name */
  BEGIN(ST_LOOKING_FOR_COLON);
  tok('?');
}

<ST_PHP>"}"/":"[a-zA-Z_\x7f-\xff] {
  // We need to be robust against a '}' in PHP code with
  // no corresponding '{'
  //struct yyguts_t * yyg = (struct yyguts_t*)yyscanner;
  if (yyg->yy_start_stack_ptr) {
    pop_state();
    if (YY_START == ST_PHP) {
      /* If XHP is enabled and "}:" occurs (and "}" does not cause us
         to transition to some state other than ST_IN_SCRIPTING), drop
         into the ST_LOOKING_FOR_COLON state to avoid potentially
         treating ":" as the beginning of an XHP class name */
      BEGIN(ST_LOOKING_FOR_COLON);
    }
  }
  tok('}');
}
<ST_PHP>"}" {
  // We need to be robust against a '}' in PHP code with
  // no corresponding '{'
  //struct yyguts_t * yyg = (struct yyguts_t*)yyscanner;
  if (yyg->yy_start_stack_ptr) pop_state();
  tok('}');
}
<ST_LOOKING_FOR_COLON>":" {
  BEGIN(ST_PHP);
  tok(':');
}

 /* XHP */
<ST_PHP>"<"[a-zA-Z_\x7f-\xff] {
  int ntt = getNextTokenType(last_token());

  if (ntt & NextTokenType::XhpTag) {
    yyless(1);
    push_state(ST_XHP_IN_TAG);
    tok(T_XHP_TAG_LT);
  }

  if (ntt & NextTokenType::XhpTagMaybe) {
    // Shift to state state ST_LT_CHECK to do a more extensive check to
    // determine if this is the beginning of an XHP tag.
    yyless(0);
    BEGIN(ST_LT_CHECK);
    YY_BREAK;
  }

  yyless(1);
  tok('<');
}

<ST_LT_CHECK>"<"{XHPLABEL}(">"|"/>"|{WHITESPACE_AND_COMMENTS}(">"|"/>"|[a-zA-Z_\x7f-\xff])) {
  BEGIN(ST_PHP);
  yyless(1);
  push_state(ST_XHP_IN_TAG);
  tok(T_XHP_TAG_LT);
}
<ST_LT_CHECK>"<" {
  BEGIN(ST_PHP);
  tok('<');
}

<ST_DOUBLE_QUOTES,ST_BACKQUOTE,ST_PHP_HEREDOC>{
  "${" {
    push_state(ST_LOOKING_FOR_VARNAME);
    tok(T_DOLLAR_OPEN_CURLY_BRACES);
  }
  "$$"/[^a-zA-Z_\x7f-\xff${] {
    yymore();
  }
  "$"{LABEL}"->"[a-zA-Z_\x80-\xff] {
    yyless(yyleng - 3);
    push_state(ST_LOOKING_FOR_PROPERTY);
    tok(T_VARIABLE);
  }
  "$"{LABEL}"?->"[a-zA-Z_\x80-\xff] {
    yyless(yyleng - 4);
    push_state(ST_LOOKING_FOR_PROPERTY);
    tok(T_VARIABLE);
  }
  "$"{LABEL}"[" {
    yyless(yyleng - 1);
    push_state(ST_VAR_OFFSET);
    tok(T_VARIABLE);
  }
  "$"{LABEL} {
    tok(T_VARIABLE);
  }
  "{$" {
    yyless(1);
    push_state(ST_PHP);
    tok(T_CURLY_OPEN);
  }
}
<ST_DOUBLE_QUOTES>{
  {DOUBLE_QUOTES_CHARS}+ {
    yy_scan_newlines(yytext, yyleng, yyg);
    tok(T_ENCAPSED_AND_WHITESPACE);
  }
  {DOUBLE_QUOTES_CHARS}*("{"{2,}|"$"{2,}|(("{"+|"$"+)[\"])) {
    yy_scan_newlines(yytext, yyleng, yyg);
    yyless(yyleng - 1);
    tok(T_ENCAPSED_AND_WHITESPACE);
  }
  [\"] {
    pop_state();
    tok('"');
  }
}

<ST_BACKQUOTE>{
  {BACKQUOTE_CHARS}+ {
    yy_scan_newlines(yytext, yyleng, yyg);
    tok(T_ENCAPSED_AND_WHITESPACE);
  }
  {BACKQUOTE_CHARS}*("{"{2,}|"$"{2,}|(("{"+|"$"+)[\"])) {
    yy_scan_newlines(yytext, yyleng, yyg);
    yyless(yyleng - 1);
    tok(T_ENCAPSED_AND_WHITESPACE);
  }
  [\`] {
    pop_state();
    tok('`');
  }
}

<ST_LOOKING_FOR_VARNAME>{
  {LABEL}[[}] {
    yyless(yyleng - 1);
    pop_state();
    push_state(ST_PHP);
    tok(T_STRING_VARNAME);
  }
  {ANY_CHAR} {
    yyless(0);
    pop_state();
    push_state(ST_PHP);
  }
}

<ST_VAR_OFFSET>{
  [0]|([1-9][0-9]*) {
    tok(T_NUM_STRING);
  }
  {LNUM}|{HNUM}|{BNUM}|{ONUM} {
    tok(T_NUM_STRING);
  }
  "$"{LABEL} {
    tok(T_VARIABLE);
  }
  "]" {
    pop_state();
    tok(']');
  }
  {TOKENS}|[[(){}"`] {
    tok(yytext[0]);
  }
  [ \n\r\t\\'#] {
    yyless(0);
    pop_state();
    tok(T_ENCAPSED_AND_WHITESPACE);
  }
  {LABEL} {
    tok(T_STRING);
  }
  {ANY_CHAR} {
    tok(T_BAD_CHARACTER);
  }
}

 /* (HERE|NOW)DOC's */
<ST_PHP,ST_PHP_NO_RESERVED_WORDS>b?"<<<"{TABS_AND_SPACES} {
  push_state(ST_PHP_HEREDOC_START);
  yyextra->heredoc_yyleng = yyleng;
  yymore();
}
<ST_PHP_HEREDOC_START>{
  "'"{LABEL}"'"|\"{LABEL}\" {
    // Create a new string for the heredoc label. Since we're using yymore above
    // yytext will actually start at the "<<<" and not the label. Use of
    // heredoc_yyleng jumps past that. Then we add 1 to get past the " or '. The
    // match is similar to calculate length.
    yyextra->heredoc_label = string(yytext + yyextra->heredoc_yyleng + 1, yyleng - yyextra->heredoc_yyleng - 2);
    set_state(ST_PHP_HEREDOC_NSTART);
    yyextra->heredoc_is_nowdoc = true;
    yymore();
  }
  {LABEL} {
    yyextra->heredoc_label = string(yytext + yyextra->heredoc_yyleng);
    set_state(ST_PHP_HEREDOC_NSTART);
    yyextra->heredoc_is_nowdoc = false;
    yymore();
  }
}
<ST_PHP_HEREDOC_NSTART>{NEWLINE} {
  ++yyextra->lineno;
  set_state(ST_PHP_HEREDOC);
  yyextra->heredoc_checked_for_immediate_end = false;
  yyextra->heredoc_yyleng = 0;
  tok(T_START_HEREDOC);
}
<ST_PHP_HEREDOC>{
  [^$\{]{ANY_CHAR}+ {
    char *cursor = yytext, *end = YY_CURRENT_BUFFER_LVALUE->yy_ch_buf + yyg->yy_n_chars;

    int indentation = 0;

    // If we just began the heredoc, check for an immediate end label.
    if (yyextra->heredoc_checked_for_immediate_end == false) {
      --cursor;
      --yyextra->lineno;
      yyextra->heredoc_checked_for_immediate_end = true;
    }

    while(cursor < end) {

      switch(*cursor++) {
        case '\r':
          if (*cursor == '\n') {
            cursor++;
          }
          /* intentional fallthrough */
        case '\n':
          ++yyextra->lineno;

          indentation = 0;

          while(cursor < end && (*cursor == ' ' || *cursor == '\t')) {
            ++cursor;
            ++indentation;
          }

          if (cursor >= end) {
            goto heredoc_scan_done;
          }

          /* Check for ending label on the next line */
          if (strncmp(yyextra->heredoc_label.c_str(), cursor, yyextra->heredoc_label.size()) == 0) {

            if (IS_LABEL_SUCCESSOR(cursor[yyextra->heredoc_label.size()])) {
              continue;
            }

            cursor -= indentation;

            set_state(ST_PHP_HEREDOC_END);
            goto heredoc_scan_done;
          }
          continue;
        case '$':
          if (yyextra->heredoc_is_nowdoc == false && (IS_LABEL_START(*cursor) || *cursor == '{')) {
            break;
          }
          continue;
        case '{':
          if (yyextra->heredoc_is_nowdoc == false && *cursor == '$') {
            break;
          }
          continue;
        case '\\':
          if (cursor < end && *cursor != '\n' && *cursor != '\r') {
            cursor++;
          }
          continue;
        default:
          continue;
      }

      cursor--;
      break;
    }
    heredoc_scan_done:
      yyless(cursor - yytext);
      if (cursor != yytext) {
        tok(T_ENCAPSED_AND_WHITESPACE);
      }
  }
}

<ST_PHP_HEREDOC_END>{
  {TABS_AND_SPACES}{LABEL} {
    pop_state();
    tok(T_END_HEREDOC);
  }
}

<ST_LOOKING_FOR_PROPERTY>{
  {WHITESPACE}+ {
    yy_scan_newlines(yytext, yyleng, yyg);
    tok(T_WHITESPACE);
  }
  "->" tok(T_OBJECT_OPERATOR);
  "?->" tok(T_NULLSAFE_OBJECT_OPERATOR);
  ":" {
    pop_state();
    push_state(ST_LOOKING_FOR_XHP_ATTRIBUTE);
    tok(':');
  }
  {LABEL} {
    pop_state();
    tok(T_STRING);
  }
  {ANY_CHAR} {
    yyless(0);
    pop_state();
  }
}

<ST_LOOKING_FOR_XHP_ATTRIBUTE>{
  {XHPLABEL} {
    pop_state();
    tok(T_XHP_LABEL);
  }
  {ANY_CHAR} {
    yyless(0);
    pop_state();
  }
}



 /* XHP */
<ST_XHP_IN_TAG>{
  {XHPLABEL} {
   tok(T_XHP_LABEL);
  }
  "=" {
    tok(yytext[0]);
  }
  ["][^"]*["] {
    // Need not to skipp the quite:
    // yytext++; yyleng--; yytext[yyleng-1] = 0; // skipping "quote"
    tok_consume();
    yylval->xhpDecode();
    tok_return(T_XHP_TEXT);
  }
  [{] {
    push_state(ST_PHP);
    tok('{');
  }
  ">" {
    BEGIN(ST_XHP_CHILD);
    tok(T_XHP_TAG_GT);
  }
  "/>" {
    BEGIN(ST_XHP_END_SINGLETON_TAG);
    yyless(1);
    tok('/');
  }
  {ANY_CHAR} {
    // This rule ensures we get a reasonable syntax error message
    // when unexpected characters occur inside XHP tags
    if (!yyextra->terminated) {
      yyextra->error = string("Invalid entity: (") + yytext + ")";
      yyextra->terminated = true;
    }
    tok(yytext[0]);
  }
}

<ST_XHP_END_SINGLETON_TAG>">" {
  pop_state();
  tok(T_XHP_TAG_GT);
}

<ST_XHP_CHILD>{
  [^{<]+ {
    yy_scan_newlines(yytext, yyleng, yyg);
    tok_consume();
    if (!yylval->htmlTrim()) {
      YY_BREAK;
    }
    yylval->squote_escape();
    yylval->xhpDecode();
    tok_return(T_XHP_TEXT);
  }
  "{" {
    push_state(ST_PHP);
    tok('{');
  }
  "<" {
    yy_scan_newlines(yytext, yyleng, yyg);
    push_state(ST_XHP_IN_TAG);
    tok(T_XHP_TAG_LT);
  }
  "</" {
    BEGIN(ST_XHP_END_CLOSE_TAG);
    yyless(yyleng - 1);
    tok(T_XHP_TAG_LT);
  }
}

<ST_XHP_END_CLOSE_TAG>{
  "/" tok('/');
  {XHPLABEL} tok(T_XHP_LABEL);
  ">" { pop_state(); tok(T_XHP_TAG_GT); }
}

<ST_XHP_CHILD>"<!--" {
  push_state(ST_XHP_COMMENT);
  yymore();
}

<ST_XHP_COMMENT>{
  [^-]+ {
    yymore();
  }
  "-->" {
    pop_state();
    tok(T_COMMENT);
  }
  "-" {
    yymore();
  }
}

 /* PHP has a rule with {ANY_CHAR} emitting T_BAD_CHARACTER, but various parts
  * of this file rely on the below behavior of emitting random characters as-is.
  *
  * So unless that ever gets cleaned up, emit T_BAD_CHARACTER for things that
  * are always invalid.
  */
<*>[\x00-\x09\x0b\x0c\x0e-\x1f] {
  tok(T_BAD_CHARACTER);
}

 /* Other */
<*>{ANY_CHAR} {
  tok(yytext[0]);

  // fix unused function warnings
  yy_top_state(NULL);
  yyunput(0, 0, NULL);
}

%%

#ifdef DEBUG
static const char* yy_state_name(int state) {
  switch (state) {
    case INITIAL:
      return "INITIAL";
    case ST_PHP:
      return "ST_PHP";
    case ST_PHP_COMMENT:
      return "ST_PHP_COMMENT";
    case ST_PHP_EOL_COMMENT:
      return "ST_PHP_EOL_COMMENT";
    case ST_PHP_DOC_COMMENT:
      return "ST_PHP_DOC_COMMENT";
    case ST_PHP_HEREDOC_START:
      return "ST_PHP_HEREDOC_START";
    case ST_PHP_HEREDOC_NSTART:
      return "ST_PHP_HEREDOC_NSTART";
    case ST_PHP_HEREDOC:
      return "ST_PHP_HEREDOC";
    case ST_PHP_HEREDOC_END:
      return "ST_PHP_HEREDOC_END";
    case ST_PHP_NO_RESERVED_WORDS:
      return "ST_PHP_NO_RESERVED_WORDS";
    case ST_XHP_CHILD:
      return "ST_XHP_CHILD";
    case ST_XHP_ATTR_TYPE_DECL:
      return "ST_XHP_ATTR_TYPE_DECL";
    case ST_XHP_CHILDREN_DECL:
      return "XHP_CHILDREN_DECL";
    case ST_XHP_COMMENT:
      return "ST_XHP_COMMENT";
    case ST_BACKQUOTE:
      return "ST_BACKQUOTE";
    case ST_DOUBLE_QUOTES:
      return "ST_DOUBLE_QUOTES";
    case ST_LOOKING_FOR_PROPERTY:
      return "ST_LOOKING_FOR_PROPERTY";
    case ST_LOOKING_FOR_VARNAME:
      return "ST_LOOKING_FOR_VARNAME";
    case ST_LOOKING_FOR_XHP_ATTRIBUTE:
      return "ST_LOOKING_FOR_XHP_ATTRIBUTE";
    case ST_VAR_OFFSET:
      return "ST_VAR_OFFSET";
    default:
      return "???";
  }
}

static void yy_log_token(int tok) {
  const char* tokname = yytokname(tok);
  if (tokname) {
    fprintf(stderr, "--> %s\n", tokname);
  } else {
    fprintf(stderr, "--> '%c'\n", tok);
  }
}
#endif

static int yy_token(int tok, yyguts_t* yyg) {
  if (YY_START == ST_PHP_NO_RESERVED_WORDS) {
    pop_state();
  }

  if (tok != T_START_HEREDOC) {
    // If we encounter anything after starting a heredoc, then it's pretty
    // obvious that the heredoc end label isn't immediately after the start.
    yyextra->heredoc_checked_for_immediate_end = true;
  }

  switch (tok) {
    case T_OPEN_TAG:
    case T_OPEN_TAG_WITH_ECHO:
    case T_OPEN_TAG_FAKE:
      // If INITIAL is on the stack, the PHP block was closed and reopened. Pop
      // that so we don't lose context (like being inside a block of curly
      // braces).
      if (yyg->yy_start_stack_ptr && YY_START == INITIAL) {
        pop_state();
      } else {
        push_state(ST_PHP);
      }
      break;

    case T_CLOSE_TAG:
      push_state(INITIAL);
      break;

    // In PHP it's ok to use keywords such as 'if' as field names
    // or function names.
    case T_PAAMAYIM_NEKUDOTAYIM:
    case T_FUNCTION:
    case T_CLASS:
      push_state(ST_PHP_NO_RESERVED_WORDS);
      break;

    case T_XHP_LABEL:
      if (yyextra->return_all_tokens) {
        yylval->prepend(":");
      }
      break;

  }
#ifdef DEBUG
  yy_log_token(tok);
#endif
  if (shouldReturnToken(tok, false)) {
    yyextra->last_token = tok;

    if (yyextra->has_doc_block) {
      *yylval = yyextra->doc_block + *yylval;
      yyextra->has_doc_block = false;
    }
  }
  return tok;
}

static inline void yy_scan_newlines(const char* text, size_t len, struct yyguts_t* yyg) {
  const char *end = text + len;
  for (; text < end; ++text) {
    if (*text == '\r') {
      if (text[1] == '\n') {
        ++text;
      }
      ++yyextra->lineno;
    } else if (*text == '\n') {
      ++yyextra->lineno;
    }
  }
}

void xhp_new_push_state(int s, struct yyguts_t* yyg) {
#ifdef DEBUG
  fprintf(stderr, "--> PUSH(%s -> %s)\n", yy_state_name(YY_START), yy_state_name(s));
#endif
  yy_push_state(s, yyg);
}

void xhp_new_pop_state(struct yyguts_t* yyg) {
#ifdef DEBUG
  int s = YY_START;
#endif
  yy_pop_state(yyg);
#ifdef DEBUG
  fprintf(stderr, "--> POP(%s -> %s)\n", yy_state_name(s), yy_state_name(YY_START));
#endif
}

void xhp_set_state(int s, struct yyguts_t* yyg) {
#ifdef DEBUG
  fprintf(stderr, "--> SET(%s)\n", yy_state_name(s));
#endif
  BEGIN(s);
}
