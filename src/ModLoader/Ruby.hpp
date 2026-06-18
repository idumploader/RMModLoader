#pragma once

#include <concepts>
#include <cstdint>
#include <type_traits>

namespace rm_modloader {
	using RubyValue = unsigned int;

	using RubyValueInnerType = RubyValue;
	using RubyValueFlag      = RubyValue;

	//using RubyValueInnerType = unsigned int;
	//struct RubyValueFlag {
	//	constexpr explicit RubyValueFlag(unsigned int val) : value(val) {}
	//	RubyValueInnerType value;
	//};

	//struct RubyValue {
	//	constexpr explicit RubyValue(unsigned int val) : value(val) {}

	//	friend constexpr bool operator==(const RubyValue& lhs, const RubyValue& rhs) {
	//		return lhs.value == rhs.value;
	//	}

	//	friend constexpr bool operator==(const RubyValue& lhs, const RubyValueFlag& rhs) {
	//		return lhs.value == rhs.value;
	//	}

	//	friend constexpr RubyValue operator&(const RubyValue& lhs, const RubyValue& rhs) {
	//		return RubyValue{ lhs.value & rhs.value };
	//	}

	//	friend constexpr RubyValue operator&(const RubyValue& lhs, const RubyValueFlag& rhs) {
	//		return RubyValue{ lhs.value & rhs.value };
	//	}

	//	friend constexpr RubyValue operator>>(const RubyValue& lhs, const int& rhs) {
	//		return RubyValue{ lhs.value >> rhs };
	//	}

	//	RubyValueInnerType value;
	//};

	using RubyID = unsigned int;

	inline constexpr RubyValue ruby_false{ 0 };
	inline constexpr RubyValue ruby_true { 2 };
	inline constexpr RubyValue ruby_nil  { 4 };
	inline constexpr RubyValue ruby_undef{ 6 };

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

	inline constexpr long ruby_bignum_embed_len_max = sizeof(RubyValue) * 3 / sizeof(RubyBDigit);
	inline constexpr long ruby_string_embed_len_max = sizeof(RubyValue) * 3 / sizeof(char) - 1;

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

	inline constexpr int ruby_special_shift                 { 8 };
	inline constexpr int ruby_flags_ushift                  { 12 };
	inline constexpr RubyValueFlag ruby_fixnum_flag         { 0x1 };
	inline constexpr RubyValueFlag ruby_symbol_flag         { 0xe };
	inline constexpr RubyValueFlag ruby_immediate_mask      { 0x3 };
	inline constexpr RubyValueFlag ruby_flag_string_no_embed{ 1 << (ruby_flags_ushift + 1) };

	inline constexpr bool is_rb_symbol(RubyValue value) {
		constexpr RubyValueFlag symbol_mask{ (1u << ruby_special_shift) - 1u };
		return (value & symbol_mask) == ruby_symbol_flag;
	}

	inline constexpr bool is_rb_fixnum(RubyValue value) {
		return (value & ruby_fixnum_flag);
	}

	inline constexpr bool is_rb_immediate(RubyValue value) {
		return (value & ruby_immediate_mask);
	}

	inline constexpr RubyID rb_sym2id(RubyValue sym) {
		return RubyID{ static_cast<RubyValueInnerType>(sym >> ruby_special_shift) };
	}

	template<typename T>
	inline T* get_rb_data_data(RubyValue value) {
		RubyRData* data = reinterpret_cast<RubyRData*>(value);
		return static_cast<T*>(data->data);
	}

	inline RubyValueType rb_type(RubyValue value) {
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

	// Forward-declared here so Ruby.hpp need not include RMGlobal.hpp (which itself
	// includes Ruby.hpp -> circular). Canonical extern + runtime init are in RMGlobal.
	extern RubyValue(__cdecl* rb_big_new)(int len, bool is_positive);

	template<std::integral T>
	inline RubyValue rb_i642num(T value) {
		// Work on a fixed 64-bit copy so the `>> 32` below can never shift past the
		// operand width (UB) when T is 32-bit or narrower. Every current caller
		// passes a 64-bit Steam ID, so for them this is a no-op.
		using Wide = std::conditional_t<std::signed_integral<T>, int64_t, uint64_t>;
		Wide num = value;
		if constexpr (std::signed_integral<T>) {
			if ((abs(num) >> 31) == 0)
				return rb_make_number(static_cast<long>(num));
		}
		else {
			if ((num >> 31) == 0)
				return rb_make_number(static_cast<long>(num));
		}

		// A Bignum stores the magnitude as 32-bit digits: one covers the low 32 bits,
		// a second is only needed when the high 32 bits are non-zero. The sign is a
		// separate argument (num >= 0), not part of the digit count.
		const int digit_count = (num >> 32) == 0 ? 1 : 2;
		RubyValue big_value = rb_big_new(digit_count, num >= 0);
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

		// Callers guarantee a Fixnum or Bignum (they check_ruby_type up front); guard
		// anyway so a stray non-Bignum value can't reinterpret unrelated memory.
		if (rb_type(value) != RUBY_T_BIGNUM) {
			return 0;
		}

		RubyRBignum* big_num = reinterpret_cast<RubyRBignum*>(value);
		uint64_t out = big_num->as.ary[0];
		out |= static_cast<uint64_t>(big_num->as.ary[1]) << 32;
		return out;
	}
}