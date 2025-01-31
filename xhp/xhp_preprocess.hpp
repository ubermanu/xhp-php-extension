/*
  +----------------------------------------------------------------------+
  | XHP                                                                  |
  +----------------------------------------------------------------------+
  | Copyright (c) 2009 - 2014 Facebook, Inc. (http://www.facebook.com)   |
  +----------------------------------------------------------------------+
  | This source file is subject to version 3.01 of the PHP license,      |
  | that is bundled with this package in the file LICENSE.PHP, and is    |
  | available through the world-wide-web at the following url:           |
  | http://www.php.net/license/3_01.txt                                  |
  | If you did not receive a copy of the PHP license and are unable to   |
  | obtain it through the world-wide-web, please send a note to          |
  | license@php.net so we can mail you a copy immediately.               |
  +----------------------------------------------------------------------+
*/

#pragma once
#include <iostream>
#include <string>
#include <stdint.h>

enum XHPResult {
  XHPDidNothing,
  XHPRewrote,
  XHPErred
};

struct xhp_flags_t {
  bool short_tags;
  bool idx_expr;
  bool include_debug;
  bool eval;
  bool force_global_namespace;
};

XHPResult xhp_preprocess(std::istream &in, std::string &out, bool isEval,
                         std::string &errDescription, uint32_t &errLineno);

XHPResult xhp_preprocess(std::string &in, std::string &out, bool isEval,
                         std::string &errDescription, uint32_t &errLineno);

XHPResult xhp_preprocess(std::string &in, std::string &out,
                         std::string &errDescription, uint32_t &errLineno,
                         const xhp_flags_t &flags);

XHPResult xhp_tokenize(std::istream &in, std::string &out);
XHPResult xhp_tokenize(std::string &in, std::string &out);

const char * xhp_get_token_type_name(int64_t tok);
int xhp_lex(char* &code_str, size_t &code_str_len, size_t &lineno, void *lex_state);
void xhp_init_lexical_state(char *buffer, size_t size, void **lex_state, bool all_tokens=true);
void xhp_destroy_lexical_state(void *lex_state);
