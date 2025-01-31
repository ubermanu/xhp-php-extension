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

#include "ext.hpp"
#include "xhp/xhp_preprocess.hpp"
#include "php.h"
#include "php_ini.h"
#include "zend.h"
#include "zend_API.h"
#include "zend_compile.h"
#include "zend_operators.h"
#include "zend_hash.h"
#include "zend_extensions.h"
#include "ext/standard/info.h"
#include <string>
using namespace std;

//
// Decls
typedef zend_op_array* (zend_compile_file_t)(zend_file_handle*, int);
#if PHP_VERSION_ID >= 80000
typedef zend_op_array* (zend_compile_string_t)(zend_string*, const char*);
#else
typedef zend_op_array* (zend_compile_string_t)(zval*, char*);
#endif
static zend_compile_file_t* dist_compile_file;
static zend_compile_string_t* dist_compile_string;

typedef struct {
  const char* str;
  size_t pos;
  size_t len;
} xhp_stream_t;

//
// Globals
ZEND_BEGIN_MODULE_GLOBALS(xhp)
  bool include_debug;
  bool force_global_namespace;
ZEND_END_MODULE_GLOBALS(xhp)
ZEND_DECLARE_MODULE_GLOBALS(xhp)

#ifdef ZTS
# define XHPG(i) TSRMG(xhp_globals_id, zend_xhp_globals*, i)
#else
# define XHPG(i) (xhp_globals.i)
#endif

// These functions wese made static to zend_stream.c in r255174. These an inline copies of those functions.
static int zend_stream_getc(zend_file_handle *file_handle) {
  char buf;

  if (file_handle->handle.stream.reader(file_handle->handle.stream.handle, &buf, sizeof(buf))) {
    return (int)buf;
  }
  return EOF;
}

static size_t zend_stream_read(zend_file_handle *file_handle, char *buf, size_t len) {
  if (file_handle->handle.stream.isatty) {
    int c = '*';
    size_t n;

    for (n = 0; n < len && (c = zend_stream_getc(file_handle)) != EOF && c != '\n'; ++n)  {
        buf[n] = (char)c;
    }
    if (c == '\n') {
      buf[n++] = (char)c;
    }

    return n;
  }
  return file_handle->handle.stream.reader(file_handle->handle.stream.handle, buf, len);
}

//
// XHP Streams
size_t xhp_stream_reader(xhp_stream_t* handle, char* buf, size_t len) {
  if (len > handle->len - handle->pos) {
    len = handle->len - handle->pos;
  }
  if (len) {
    memcpy(buf, handle->str + handle->pos, len);
    buf[len] = 0;
    handle->pos += len;
    return len;
  } else {
    return 0;
  }
}

long xhp_stream_fteller(xhp_stream_t* handle) {
  return (long)handle->pos;
}

//
// PHP compilation intercepter
static zend_op_array* xhp_compile_file(zend_file_handle* f, int type) {
  // open_file_for_scanning will reset this value, so we need to preserve its
  // initial state and restore it later.
  zend_bool skip_shebang_tmp = CG(skip_shebang);

  if (!f || open_file_for_scanning(f) == FAILURE) {
    CG(skip_shebang) = skip_shebang_tmp;
    // If opening the file fails just send it to the original func
    return dist_compile_file(f, type);
  }
  CG(skip_shebang) = skip_shebang_tmp;

  // Grab code from zend file handle
  string original_code;
  if (f->buf) {
    original_code = f->buf;
  }
  else {
    // Read full program from zend stream
    char read_buf[4096];
    size_t len;
    while (len = zend_stream_read(f, (char*)&read_buf, 4095)) {
      read_buf[len] = 0;
      original_code += read_buf;
    }
  }

  // Process XHP
  XHPResult result;
  xhp_flags_t flags;
  string rewrit, error_str;
  uint32_t error_lineno;
  string* code_to_give_to_php;

  memset(&flags, 0, sizeof(xhp_flags_t));
  flags.short_tags = CG(short_tags);
  flags.include_debug = XHPG(include_debug);
  flags.force_global_namespace = XHPG(force_global_namespace);
  result = xhp_preprocess(original_code, rewrit, error_str, error_lineno, flags);

  if (result == XHPErred) {
    // Bubble error up to PHP
    CG(in_compilation) = true;
    CG(zend_lineno) = error_lineno;
#if PHP_VERSION_ID >= 80100
    zend_set_compiled_filename(f->filename);
#else
    zend_string *str = zend_string_init(f->filename, strlen(f->filename), 0);
    zend_set_compiled_filename(str);
    zend_string_release(str);
#endif

    zend_error(E_PARSE, "%s", error_str.c_str());
    zend_bailout();
  } else if (result == XHPRewrote) {
    code_to_give_to_php = &rewrit;
  } else {
    code_to_give_to_php = &original_code;
  }

  // Create a fake file to give back to PHP to handle
  zend_file_handle fake_file;
  memset(&fake_file, 0, sizeof(zend_file_handle));

  fake_file.type = ZEND_HANDLE_FILENAME;
  fake_file.opened_path = f->opened_path ? zend_string_copy(f->opened_path) : NULL;
#if PHP_VERSION_ID >= 80100
  fake_file.filename = zend_string_copy(f->filename);
#else
  fake_file.filename = f->filename;
  fake_file.free_filename = false;
#endif

  fake_file.handle.stream.isatty = 0;
  fake_file.buf = estrdup(const_cast<char*>(code_to_give_to_php->c_str()));
  fake_file.len = code_to_give_to_php->size();
  fake_file.handle.stream.closer = NULL;

  // TODO: should check for bailout
  zend_op_array* ret = dist_compile_file(&fake_file, type);

  zend_destroy_file_handle(&fake_file);

  return ret;
}

#if PHP_VERSION_ID >= 80000
static zend_op_array* xhp_compile_string(zend_string* str, const char *filename) {
#else
static zend_op_array* xhp_compile_string(zval* str, char *filename) {
#endif

  // Cast to str
#if PHP_VERSION_ID >= 80000
  zend_string *rewritten_code_str;
  char* val = ZSTR_VAL(str);
#else
  zval tmp;
  char* val;
  if (Z_TYPE_P(str) != IS_STRING) {
    tmp = *str;
    zval_copy_ctor(&tmp);
    convert_to_string(&tmp);
    val = Z_STRVAL(tmp);
  } else {
    val = Z_STRVAL_P(str);
  }
#endif

  // Process XHP
  string rewrit, error_str;
  string* code_to_give_to_php;
  uint32_t error_lineno;
  string original_code(val);
  xhp_flags_t flags;

  memset(&flags, 0, sizeof(xhp_flags_t));
  flags.short_tags = CG(short_tags);
  flags.include_debug = XHPG(include_debug);
  flags.force_global_namespace = XHPG(force_global_namespace);
  flags.eval = true;
  XHPResult result = xhp_preprocess(original_code, rewrit, error_str, error_lineno, flags);

#if PHP_VERSION_ID < 80000
  // Destroy temporary in the case of non-string input (why?)
  if (Z_TYPE_P(str) != IS_STRING) {
    zval_dtor(&tmp);
  }
#endif

  if (result == XHPErred) {

    // Bubble error up to PHP
    bool original_in_compilation = CG(in_compilation);
    CG(in_compilation) = true;
    CG(zend_lineno) = error_lineno;
    zend_error(E_PARSE, "%s", error_str.c_str());
    CG(unclean_shutdown) = 1;
    CG(in_compilation) = original_in_compilation;
    return NULL;
  } else if (result == XHPRewrote) {
    // Create another tmp zval with the rewritten PHP code and pass it to the original function
#if PHP_VERSION_ID >= 80000
    rewritten_code_str = zend_string_init(rewrit.c_str(), rewrit.size(), 0);
    zend_op_array* ret = dist_compile_string(rewritten_code_str, filename);
    zend_string_release(rewritten_code_str);
#else
    ZVAL_STRINGL(&tmp, rewrit.c_str(), rewrit.size());
    zend_op_array* ret = dist_compile_string(&tmp, filename);
    zval_dtor(&tmp);
#endif
    return ret;
  } else {
    return dist_compile_string(str, filename);
  }
}

//
// tokenize
static zend_bool tokenize(zval *return_value, zend_string *source)
{
  array_init(return_value);

  char *val = ZSTR_VAL(source);
  string in(val, source->len);

  // Create a flex buffer
  in.reserve(in.size() + 1);
  char *buffer = const_cast<char*>(in.c_str());
  buffer[in.size() + 1] = 0; // need double NULL for scan_buffer

  // Parse the PHP
  void *lex_state;
  xhp_init_lexical_state(buffer, in.size()+2, &lex_state);
  char *code_str;

  int64_t tok;
  size_t code_str_len, lineno;
  while(tok = xhp_lex(code_str, code_str_len, lineno, lex_state)) {
    // tokens should contain at least one character, but sometimes that character is a
    // null byte.
    string code_s(code_str, code_str_len);

    if (tok >= 256) {
        zval keyword;
        array_init(&keyword);
        add_next_index_long(&keyword, tok);
        add_next_index_stringl(&keyword, code_s.c_str(), code_s.length());
        add_next_index_long(&keyword, lineno);
        add_next_index_zval(return_value, &keyword);
    } else {
        if (tok >= 0x20 && tok <= 0x7E) {
            add_next_index_stringl(return_value, code_s.c_str(), code_s.length());
        } else {
            add_next_index_long(return_value, tok);
        }
    }
  }

  xhp_destroy_lexical_state(lex_state);

  return 1;
}

void xhp_tokenizer_register_constants(INIT_FUNC_ARGS);

//
// globals initialization
static void php_xhp_init_globals(zend_xhp_globals* xhp_globals) {
  xhp_globals->include_debug = true;
  xhp_globals->force_global_namespace = true;
}

//
// ini entry
PHP_INI_BEGIN()
  STD_PHP_INI_BOOLEAN("xhp.include_debug", "1", PHP_INI_PERDIR, OnUpdateBool, include_debug, zend_xhp_globals, xhp_globals)
  STD_PHP_INI_BOOLEAN("xhp.force_global_namespace", "1", PHP_INI_PERDIR, OnUpdateBool, force_global_namespace, zend_xhp_globals, xhp_globals)
PHP_INI_END()

//
// Extension entry
static PHP_MINIT_FUNCTION(xhp) {

  ZEND_INIT_MODULE_GLOBALS(xhp, php_xhp_init_globals, NULL);

  REGISTER_INI_ENTRIES();

  dist_compile_file = zend_compile_file;
  zend_compile_file = xhp_compile_file;

  xhp_tokenizer_register_constants(INIT_FUNC_ARGS_PASSTHRU);

  // For eval
  dist_compile_string = zend_compile_string;
  zend_compile_string = xhp_compile_string;
  return SUCCESS;
}

static PHP_MSHUTDOWN_FUNCTION(xhp) {
  UNREGISTER_INI_ENTRIES();
  return SUCCESS;
}

//
// phpinfo();
static PHP_MINFO_FUNCTION(xhp) {
  php_info_print_table_start();
  php_info_print_table_row(2, "Version", PHP_XHP_VERSION);
  php_info_print_table_row(2, "Include Debug Info Into XHP Classes", XHPG(include_debug) ? "enabled" : "disabled");
  php_info_print_table_row(2, "Force XHP Into The Global Namespace", XHPG(force_global_namespace) ? "enabled" : "disabled");
  php_info_print_table_end();
}

//
// xhp_preprocess_code
ZEND_BEGIN_ARG_INFO_EX(php_xhp_preprocess_code_arginfo, 0, 0, 0)
  ZEND_ARG_TYPE_INFO(0, code, IS_STRING, 0)
ZEND_END_ARG_INFO()

ZEND_FUNCTION(xhp_preprocess_code) {
  // Parse zend params
  char *code;
  int code_len;
  if (zend_parse_parameters(ZEND_NUM_ARGS(), "s", &code, &code_len) == FAILURE) {
    RETURN_NULL();
  }
  string rewrit, error;
  uint32_t error_line;

  // Mangle code
  string code_str(code, code_len);
  XHPResult result = xhp_preprocess(code_str, rewrit, false, error, error_line);

  // Build return code
  array_init(return_value);
  if (result == XHPErred) {
    add_assoc_string(return_value, "error", const_cast<char*>(error.c_str()));
    add_assoc_long(return_value, "error_line", error_line);
  } else if (result == XHPRewrote) {
    add_assoc_string(return_value, "new_code", const_cast<char*>(rewrit.c_str()));
  }
}

//
// xhp_token_get_all
ZEND_BEGIN_ARG_INFO_EX(php_xhp_token_get_all_arginfo, 0, 0, 0)
  ZEND_ARG_TYPE_INFO(0, source, IS_STRING, 0)
ZEND_END_ARG_INFO()

PHP_FUNCTION(xhp_token_get_all) {
  zend_string *source;
  zend_bool success;

  if (zend_parse_parameters(ZEND_NUM_ARGS(), "S", &source) == FAILURE) {
    return;
  }

  success = tokenize(return_value, source);

  if (!success) RETURN_FALSE;
}

//
// xhp_token_name
ZEND_BEGIN_ARG_INFO_EX(php_xhp_token_name_arginfo, 0, 0, 0)
  ZEND_ARG_TYPE_INFO(0, type, IS_LONG, 0)
ZEND_END_ARG_INFO()

PHP_FUNCTION(xhp_token_name) {
  zend_long type;

  if (zend_parse_parameters(ZEND_NUM_ARGS(), "l", &type) == FAILURE) {
    return;
  }

  RETVAL_STRING(xhp_get_token_type_name(type));
}

// xhp_rename_function
ZEND_BEGIN_ARG_INFO_EX(php_xhp_rename_function_arginfo, 0, 0, 0)
  ZEND_ARG_TYPE_INFO(0, orig_fname, IS_STRING, 0)
  ZEND_ARG_TYPE_INFO(0, new_fname, IS_STRING, 0)
ZEND_END_ARG_INFO()

PHP_FUNCTION(xhp_rename_function)
{
  zend_string *orig_fname, *new_fname;
  zval *func;

  if (zend_parse_parameters(ZEND_NUM_ARGS(), "SS", &orig_fname, &new_fname) == FAILURE) {
    return;
  }

  func = zend_hash_find(EG(function_table), orig_fname);
  if (func == NULL) {
    zend_error(E_WARNING, "%s() failed: original '%s' does not exist!",
                 get_active_function_name(),ZSTR_VAL(orig_fname));
    RETURN_FALSE;
  }

  // zend_error(E_WARNING, "name: %s", ZSTR_VAL(Z_FUNC_P(func)->common.function_name));

  if (zend_hash_exists(EG(function_table), new_fname)) {
    zend_error(E_WARNING, "%s() failed: new '%s' already exist!",
                 get_active_function_name(),ZSTR_VAL(new_fname));
    RETURN_FALSE;
  }

  if (zend_hash_add(EG(function_table), new_fname, func) == NULL) {
    zend_error(E_WARNING, "%s() failed to insert '%s' into function table",
                 get_active_function_name(), ZSTR_VAL(new_fname));
    RETURN_FALSE;
  }

  if(zend_hash_del(EG(function_table), orig_fname) == FAILURE) {
    zend_error(E_WARNING, "%s() failed to remove '%s' from function table",
              get_active_function_name(),
              ZSTR_VAL(orig_fname));

    zend_hash_del(EG(function_table), new_fname);
    RETURN_FALSE;
  }

  RETURN_TRUE;
}

//
// Module description
zend_function_entry xhp_functions[] = {
  ZEND_FE(xhp_preprocess_code, php_xhp_preprocess_code_arginfo)
  PHP_FE(xhp_token_get_all, php_xhp_token_get_all_arginfo)
  PHP_FE(xhp_token_name, php_xhp_token_name_arginfo)
  PHP_FE(xhp_rename_function, php_xhp_rename_function_arginfo)
  PHP_FE_END
};

zend_module_entry xhp_module_entry = {
  STANDARD_MODULE_HEADER,
  PHP_XHP_EXTNAME,
  xhp_functions,
  PHP_MINIT(xhp),
  PHP_MSHUTDOWN(xhp),
  NULL,
  NULL,
  PHP_MINFO(xhp),
  PHP_XHP_VERSION,
  STANDARD_MODULE_PROPERTIES
};

#ifdef COMPILE_DL_XHP
ZEND_GET_MODULE(xhp)
#endif
