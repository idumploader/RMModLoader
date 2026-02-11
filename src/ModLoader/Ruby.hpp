#pragma once

#include <concepts>

namespace rm_modloader {
	using RubyValue = unsigned int;
	using RubyID = unsigned int;

	constexpr RubyValue ruby_false = 0;
	constexpr RubyValue ruby_true = 2;
	constexpr RubyValue ruby_nil = 4;
	constexpr RubyValue ruby_undef = 6;

	enum RubyValueType {
		RUBY_T_NONE = 0x00,

		RUBY_T_OBJECT = 0x01,
		RUBY_T_CLASS = 0x02,
		RUBY_T_MODULE = 0x03,
		RUBY_T_FLOAT = 0x04,
		RUBY_T_STRING = 0x05,
		RUBY_T_REGEXP = 0x06,
		RUBY_T_ARRAY = 0x07,
		RUBY_T_HASH = 0x08,
		RUBY_T_STRUCT = 0x09,
		RUBY_T_BIGNUM = 0x0a,
		RUBY_T_FILE = 0x0b,
		RUBY_T_DATA = 0x0c,
		RUBY_T_MATCH = 0x0d,
		RUBY_T_COMPLEX = 0x0e,
		RUBY_T_RATIONAL = 0x0f,

		RUBY_T_NIL = 0x11,
		RUBY_T_TRUE = 0x12,
		RUBY_T_FALSE = 0x13,
		RUBY_T_SYMBOL = 0x14,
		RUBY_T_FIXNUM = 0x15,

		RUBY_T_UNDEF = 0x1b,
		RUBY_T_NODE = 0x1c,
		RUBY_T_ICLASS = 0x1d,
		RUBY_T_ZOMBIE = 0x1e,

		RUBY_T_MASK = 0x1f
	};

	struct RubyRBasic {
		RubyValue flags;
		RubyValue klass;
	};

	struct RubyRData {
		RubyRBasic basic;
		void(__cdecl* dmark)(void*);
		void(__cdecl* dfree)(void*);
		void* data;
	};

	// check
	using RubyBDigit = unsigned long;

	constexpr long ruby_bignum_embed_len_max = sizeof(RubyValue) * 3 / sizeof(RubyBDigit);
	constexpr long ruby_string_embed_len_max = sizeof(RubyValue) * 3 / sizeof(char) - 1;

	struct RubyRBignum {
		RubyRBasic basic;
		union {
			struct {
				long len;
				RubyBDigit* digits;
			} heap;
			RubyBDigit ary[ruby_bignum_embed_len_max];
		} as;
	};

	struct RubyRString {
		RubyRBasic basic;
		union {
			struct {
				int len;
				char* ptr;
				union {
					int capa;
					RubyValue shared;
				} aux;
			} heap;
			char ary[ruby_string_embed_len_max + 1];
		} as;
	};

	constexpr int ruby_special_shift = 8;
	constexpr int ruby_flags_ushift = 12;
	constexpr int ruby_fixnum_flag = 0x1;
	constexpr int ruby_symbol_flag = 0xe;
	constexpr int ruby_immediate_mask = 0x3;
	constexpr int ruby_flag_string_no_embed = 1 << (ruby_flags_ushift + 1);

	inline constexpr bool is_rb_symbol(RubyValue value) {
		return (value & ~(~0 >> ruby_special_shift << ruby_special_shift)) == ruby_symbol_flag;
	}

	inline constexpr bool is_rb_fixnum(RubyValue value) {
		return (value & ruby_fixnum_flag);
	}

	inline constexpr bool is_rb_immediate(RubyValue value) {
		return value & ruby_immediate_mask;
	}

	inline constexpr RubyID rb_sym2id(RubyValue sym) {
		return sym >> ruby_special_shift;
	}

	template<typename T>
	inline T* get_rb_data_data(RubyValue value) {
		RubyRData* data = reinterpret_cast<RubyRData*>(value);
		return static_cast<T*>(data->data);
	}

	constexpr RubyValueType rb_type(RubyValue value) {
		if (is_rb_immediate(value)) {
			if (value == ruby_true) return RUBY_T_TRUE;
			if (value == ruby_undef) return RUBY_T_UNDEF;
			if (is_rb_symbol(value)) return RUBY_T_SYMBOL;
			if (is_rb_fixnum(value)) return RUBY_T_FIXNUM;
		}
		else {
			if (value == ruby_nil) return RUBY_T_NIL;
			if (value == ruby_false) return RUBY_T_FALSE;
		}
		RubyValue klass = reinterpret_cast<RubyRBasic*>(value)->flags;
		return static_cast<RubyValueType>(klass & RUBY_T_MASK);
	}

	inline constexpr RubyValue rb_make_number(long number) {
		return (number & 0x7FFFFFFF) << 1 | ruby_fixnum_flag;
	}

	//inline constexpr RubyValue rb_ull2big(long long number) {
	//	return ruby_nil;
	//}

	inline RubyValue rb_get_value_klass(RubyValue value) {
		RubyRBasic* basic = reinterpret_cast<RubyRBasic*>(value);
		return basic->klass;
	}

	inline std::string_view rb_str_value(RubyValue value) {
		RubyRString* string = reinterpret_cast<RubyRString*>(value);
		if (string->basic.flags & ruby_flag_string_no_embed) {
			return std::string_view(string->as.heap.ptr, string->as.heap.len);
		}
		return std::string_view(string->as.ary);
	}

	extern RubyValue(__cdecl* rb_big_new)(int len, bool is_positive);

	template<std::integral T>
	inline RubyValue rb_i642num(T num) {
		if constexpr (std::signed_integral<T>) {
			if ((abs(num) >> 31) == 0)
				return rb_make_number(num);
		}
		else {
			if ((num >> 31) == 0)
				return rb_make_number(num);
		}

		RubyValue big_value = rb_big_new((num >> 32) == 0 ? 1 : 2, num >= 0);
		RubyRBignum* big_num = reinterpret_cast<RubyRBignum*>(big_value);
		if constexpr (std::signed_integral<T>) {
			num = abs(num);
		}
		big_num->as.ary[0] = num & 0xFFFFFFFF;
		big_num->as.ary[1] = num >> 32;
		return big_value;
	}

	inline uint64_t rb_num2ull(RubyValue value) {
		if (is_rb_fixnum(value)) {
			return value >> 1;
		}

		// TODO: check for bignum

		RubyRBignum* big_num = reinterpret_cast<RubyRBignum*>(value);
		uint64_t out = big_num->as.ary[0];
		out |= static_cast<uint64_t>(big_num->as.ary[1]) << 32;
		return out;
	}
}