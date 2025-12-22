#include "SteamSupportHooks.hpp"
#include "../ModLoader.hpp"

#include "../Steam/isteammatchmaking.h"
#include "../Steam/isteamnetworkingmessages.h"

#include <sstream>

#undef min
#undef max

namespace rm_modloader {
	HMODULE steam_api_module = nullptr;
	HSteamUser(__cdecl* SteamAPI_GetHSteamUser)() = nullptr;
	void* (__cdecl* SteamAPI_FindOrCreateUserInterface)(int32_t steam_user, const char* version) = nullptr;

	void(__cdecl* SteamAPI_RegisterCallback)(class CCallbackBase* pCallback, int iCallback);
	void(__cdecl* SteamAPI_UnregisterCallback)(class CCallbackBase* pCallback);
	void(__cdecl* SteamAPI_RegisterCallResult)(class CCallbackBase* pCallback, SteamAPICall_t hAPICall) = nullptr;
	void(__cdecl* SteamAPI_UnregisterCallResult)(class CCallbackBase* pCallback, SteamAPICall_t hAPICall) = nullptr;

	inline ISteamMatchmaking* SteamMatchmaking() {
		return static_cast<ISteamMatchmaking*>(SteamAPI_FindOrCreateUserInterface(SteamAPI_GetHSteamUser(), STEAMMATCHMAKING_INTERFACE_VERSION));
	}

	inline ISteamFriends* SteamFriends() {
		return static_cast<ISteamFriends*>(SteamAPI_FindOrCreateUserInterface(SteamAPI_GetHSteamUser(), STEAMFRIENDS_INTERFACE_VERSION));
	}

	inline ISteamNetworkingMessages* SteamNetworkingMessages() {
		return static_cast<ISteamNetworkingMessages*>(SteamAPI_FindOrCreateUserInterface(SteamAPI_GetHSteamUser(), STEAMNETWORKINGMESSAGES_INTERFACE_VERSION));
	}

	constexpr size_t get_callback_type_size(int callback_type) {
		switch (callback_type) {
		case LobbyCreated_t::k_iCallback:
			return sizeof(LobbyCreated_t);
		case LobbyEnter_t::k_iCallback:
			return sizeof(LobbyEnter_t);
		case LobbyChatUpdate_t::k_iCallback:
			return sizeof(LobbyChatUpdate_t);
		case GameLobbyJoinRequested_t::k_iCallback:
			return sizeof(GameLobbyJoinRequested_t);
		default:
			return 0;
		}
	}

	template<typename ... Args>
	void debug_mod_loader_log(std::format_string<Args...> fmt, Args&& ... args) {
#ifdef _DEBUG
		mod_loader->log_info(std::move(fmt), std::forward<Args>(args) ...);
#endif
	}

	template<typename ... T>
	inline bool check_ruby_type(RubyValue value, T ... expected_types) {
		return ((rb_type(value) == expected_types) || ...);
	}

	using SteamCCallbackRunner = void(*)(RubyValue recv, RubyID method, void* pv_param, bool failure);
	//struct CallbackRunner {
	//	virtual void run(void* pv_param, bool failure, uint64_t steam_api_call) = 0;
	//};

	void lobby_created_callback_runner(RubyValue recv, RubyID method, void* pv_param, bool failure) {
		LobbyCreated_t* result = static_cast<LobbyCreated_t*>(pv_param);

		debug_mod_loader_log("Steam callback run: lobby id: {}, status: {}, failure: {}\n",
			result->m_ulSteamIDLobby,
			static_cast<int>(result->m_eResult),
			failure
		);

		rb_funcall(recv, method, 3,
			rb_make_number(result->m_eResult),
			rb_i642num(result->m_ulSteamIDLobby),
			failure ? ruby_true : ruby_false
		);
	}

	void lobby_enter_callback_runner(RubyValue recv, RubyID method, void* pv_param, bool failure) {
		LobbyEnter_t* result = static_cast<LobbyEnter_t*>(pv_param);

		rb_funcall(recv, method, 3,
			rb_make_number(result->m_EChatRoomEnterResponse),
			rb_i642num(result->m_ulSteamIDLobby),
			failure ? ruby_true : ruby_false
		);
	}

	void lobby_chat_update_callback_runner(RubyValue recv, RubyID method, void* pv_param, bool failure) {
		LobbyChatUpdate_t* result = static_cast<LobbyChatUpdate_t*>(pv_param);

		rb_funcall(recv, method, 4,
			rb_i642num(result->m_ulSteamIDLobby),
			rb_make_number(result->m_rgfChatMemberStateChange),
			rb_i642num(result->m_ulSteamIDUserChanged),
			failure ? ruby_true : ruby_false
		);
	}

	void lobby_join_requested_callback_runner(RubyValue recv, RubyID method, void* pv_param, bool failure) {
		GameLobbyJoinRequested_t* result = static_cast<GameLobbyJoinRequested_t*>(pv_param);

		rb_funcall(recv, method, 3,
			rb_i642num(result->m_steamIDLobby.ConvertToUint64()),
			rb_i642num(result->m_steamIDFriend.ConvertToUint64()),
			failure ? ruby_true : ruby_false
		);
	}

	constexpr SteamCCallbackRunner get_callback_runner(int callback_type) {
		switch (callback_type) {
		case LobbyCreated_t::k_iCallback:
			return lobby_created_callback_runner;
		case LobbyEnter_t::k_iCallback:
			return lobby_enter_callback_runner;
		case LobbyChatUpdate_t::k_iCallback:
			return lobby_chat_update_callback_runner;
		case GameLobbyJoinRequested_t::k_iCallback:
			return lobby_join_requested_callback_runner;
		default:
			nullptr;
		}
	}

	struct SteamCCallResult : CCallbackBase {
		static RubyValue klass;

		SteamCCallResult() = default;

		SteamCCallResult(int callback_type) {
			m_iCallback = callback_type;
		}
		
		~SteamCCallResult() {
			if (api_call_) {
				SteamAPI_UnregisterCallResult(this, api_call_);
			}
		}

		virtual void Run(void* pv_param) override {
			api_call_ = 0;
			debug_mod_loader_log("Steam callback run: {:X}\n", reinterpret_cast<uintptr_t>(pv_param));

			if (auto callback_runner = get_callback_runner(m_iCallback)) {
				callback_runner(recv_, method_, pv_param, false);
			}
		}

		virtual void Run(void* pv_param, bool failure, uint64_t steam_api_call) override {
			debug_mod_loader_log("Steam callback run: {:X}, {}, {}\n", reinterpret_cast<uintptr_t>(pv_param), failure, steam_api_call);

			if (api_call_ != steam_api_call) {
				api_call_ = 0;
				return;
			}
			api_call_ = 0;

			if (auto callback_runner = get_callback_runner(m_iCallback)) {
				callback_runner(recv_, method_, pv_param, failure);
			}
		}

		virtual int GetCallbackSizeBytes() override {
			debug_mod_loader_log("Steam callback get size bytes\n");
			return get_callback_type_size(m_iCallback);
		}

		static void __cdecl dealloc(void* block) {
			debug_mod_loader_log("Steam callback free: {:X}\n", reinterpret_cast<uintptr_t>(block));
			SteamCCallResult* callback = static_cast<SteamCCallResult*>(block);
			callback->~SteamCCallResult();

			rgss_free(block);
		}

		static RubyValue __cdecl alloc(RubyValue klass) {
			SteamCCallResult* callback = static_cast<SteamCCallResult*>(alloc_rb_rdata(sizeof(SteamCCallResult)));
			new(callback) SteamCCallResult();

			debug_mod_loader_log("Allocated steam callback: {:X}. klass = {}, fun klass = {}\n", reinterpret_cast<uintptr_t>(callback), SteamCCallResult::klass, klass);

			return make_rb_rdata(klass, callback, nullptr, dealloc);
		}

		static RubyValue __cdecl initialize(RubyValue object, RubyValue callback_type_value) {
			if (!is_rb_fixnum(callback_type_value)) {
				rb_raise(*ruby_error_arg_error, "Expected callback_type as fixnum");
				return ruby_nil;
			}

			SteamCCallResult* callback = get_rb_data_data<SteamCCallResult>(object);
			callback->set_callback_type(rb_parse_int(callback_type_value));

			debug_mod_loader_log("Steam callback init. Pointer: {:X}\n", reinterpret_cast<uintptr_t>(callback));
			return object;
		}

		static RubyValue __cdecl set_ruby(RubyValue object, RubyValue api_call, RubyValue recv, RubyValue symbol) {
			if (!is_rb_symbol(symbol)) {
				rb_raise(*ruby_error_arg_error, "SteamCallbackBase: Expected symbol");
				return ruby_nil;
			}
			SteamCCallResult* callback = get_rb_data_data<SteamCCallResult>(object);
			debug_mod_loader_log("Steam callback set. Pointer: {:X}. {} ({}), {}, {}\n",
				reinterpret_cast<uintptr_t>(callback),
				api_call,
				rb_parse_int(api_call),
				recv,
				symbol
			);

			callback->set(rb_parse_int(api_call), recv, rb_sym2id(symbol));
			return ruby_true;
		}

		static RubyValue __cdecl register_ruby(RubyValue object, RubyValue recv, RubyValue symbol) {
			if (!is_rb_symbol(symbol)) {
				rb_raise(*ruby_error_arg_error, "SteamCallbackBase: Expected symbol");
				return ruby_nil;
			}
			SteamCCallResult* callback = get_rb_data_data<SteamCCallResult>(object);
			debug_mod_loader_log("Steam callback register. Pointer: {:X}, {}, {}\n",
				reinterpret_cast<uintptr_t>(callback),
				recv,
				symbol
			);

			callback->register_handler(recv, rb_sym2id(symbol));
			return ruby_true;
		}

		void set(uint64_t api_call, RubyValue recv, RubyID method) {
			if (api_call_) {
				SteamAPI_UnregisterCallResult(this, api_call_);
			}

			api_call_ = api_call;
			recv_ = recv;
			method_ = method;

			if (api_call) {
				SteamAPI_RegisterCallResult(this, api_call);
			}
		}

		void set_callback_type(int callback_type) {
			m_iCallback = callback_type;
		}

		void register_handler(RubyValue recv, RubyID method) {
			recv_ = recv;
			method_ = method;
		}

		void set_api_call(SteamAPICall_t api_call) {
			if (api_call_) {
				SteamAPI_UnregisterCallResult(this, api_call_);
			}

			api_call_ = api_call;

			if (api_call) {
				SteamAPI_RegisterCallResult(this, api_call);
			}
		}

	private:
		uint64_t api_call_ = 0;
		RubyValue recv_ = ruby_nil;
		RubyID method_ = ruby_nil;
	};

	RubyValue SteamCCallResult::klass = 0;

	struct SteamCCallback : CCallbackBase {
		static RubyValue klass;

		SteamCCallback() = default;

		SteamCCallback(int callback_type) {
			m_iCallback = callback_type;
		}

		~SteamCCallback() {
			if (m_iCallback) {
				SteamAPI_UnregisterCallback(this);
			}
		}

		virtual void Run(void* pv_param) override {
			debug_mod_loader_log("Steam callback run: {:X}\n", reinterpret_cast<uintptr_t>(pv_param));

			if (auto callback_runner = get_callback_runner(m_iCallback)) {
				callback_runner(recv_, method_, pv_param, false);
			}
		}

		virtual void Run(void* pv_param, bool failure, uint64_t steam_api_call) override {
			debug_mod_loader_log("Steam callback run: {:X}, {}, {}\n", reinterpret_cast<uintptr_t>(pv_param), failure, steam_api_call);

			if (auto callback_runner = get_callback_runner(m_iCallback)) {
				callback_runner(recv_, method_, pv_param, failure);
			}
		}

		virtual int GetCallbackSizeBytes() override {
			debug_mod_loader_log("Steam callback get size bytes\n");
			return get_callback_type_size(m_iCallback);
		}

		static void __cdecl dealloc(void* block) {
			debug_mod_loader_log("Steam callback free: {:X}\n", reinterpret_cast<uintptr_t>(block));
			SteamCCallResult* callback = static_cast<SteamCCallResult*>(block);
			callback->~SteamCCallResult();

			rgss_free(block);
		}

		static RubyValue __cdecl alloc(RubyValue klass) {
			SteamCCallback* callback = static_cast<SteamCCallback*>(alloc_rb_rdata(sizeof(SteamCCallback)));
			new(callback) SteamCCallback();

			debug_mod_loader_log("Allocated steam callback: {:X}. klass = {}, fun klass = {}\n", reinterpret_cast<uintptr_t>(callback), SteamCCallback::klass, klass);

			return make_rb_rdata(klass, callback, nullptr, dealloc);
		}

		static RubyValue __cdecl initialize(RubyValue object, RubyValue callback_type_value, RubyValue recv, RubyValue method) {
			if (!check_ruby_type(callback_type_value, RUBY_T_FIXNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected callback type as fixnum");
				return ruby_nil;
			}
			if (!check_ruby_type(method, RUBY_T_SYMBOL)) {
				rb_raise(*ruby_error_arg_error, "Expected method as symbol");
				return ruby_nil;
			}

			SteamCCallback* callback = get_rb_data_data<SteamCCallback>(object);
			callback->register_handler(recv, rb_sym2id(method));
			callback->set_callback_type(rb_parse_int(callback_type_value));

			debug_mod_loader_log("Steam callback init. Pointer: {:X}\n", reinterpret_cast<uintptr_t>(callback));
			return object;
		}

		static RubyValue __cdecl register_ruby(RubyValue object, RubyValue recv, RubyValue symbol) {
			if (!is_rb_symbol(symbol)) {
				rb_raise(*ruby_error_arg_error, "SteamCallbackBase: Expected symbol");
				return ruby_nil;
			}
			SteamCCallback* callback = get_rb_data_data<SteamCCallback>(object);
			debug_mod_loader_log("Steam callback register. Pointer: {:X}, {}, {}\n",
				reinterpret_cast<uintptr_t>(callback),
				recv,
				symbol
			);

			callback->register_handler(recv, rb_sym2id(symbol));
			return ruby_true;
		}

		void set_callback_type(int callback_type) {
			if (m_iCallback) {
				SteamAPI_UnregisterCallback(this);
			}

			m_iCallback = callback_type;

			if (callback_type) {
				SteamAPI_RegisterCallback(this, callback_type);
			}
		}

		void register_handler(RubyValue recv, RubyID method) {
			recv_ = recv;
			method_ = method;
		}

	private:
		RubyValue recv_ = ruby_nil;
		RubyID method_ = 0;
	};

	RubyValue SteamCCallback::klass = 0;

	struct BasicNetworkPacket {
		static RubyValue klass;

		static constexpr uint32_t magic = 0xFEFE1234;

		std::string data;
		uint64_t from_id;
		int32_t type;

		static void __cdecl dealloc(void* block) {
			BasicNetworkPacket* packet = static_cast<BasicNetworkPacket*>(block);
			packet->~BasicNetworkPacket();

			rgss_free(block);
		}

		static RubyValue __cdecl alloc(RubyValue klass) {
			BasicNetworkPacket* packet = static_cast<BasicNetworkPacket*>(alloc_rb_rdata(sizeof(BasicNetworkPacket)));
			new(packet) BasicNetworkPacket();

			return make_rb_rdata(klass, packet, nullptr, dealloc);
		}

		static RubyValue __cdecl initialize(RubyValue object, RubyValue type_value, RubyValue from_id_value, RubyValue data_value) {
			if (!check_ruby_type(from_id_value, RUBY_T_FIXNUM, RUBY_T_BIGNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected from_id as fixnum or bignum");
				return ruby_nil;
			}

			BasicNetworkPacket* packet = get_rb_data_data<BasicNetworkPacket>(object);
			packet->type = rb_parse_int(type_value);
			packet->from_id = rb_num2ull(from_id_value);
			packet->data = rb_get_string_data(&data_value);

			return object;
		}

		static RubyValue __cdecl get_type_ruby(RubyValue object) {
			BasicNetworkPacket* packet = get_rb_data_data<BasicNetworkPacket>(object);

			return rb_make_number(packet->type);
		}

		static RubyValue __cdecl set_type_ruby(RubyValue object, RubyValue type_value) {
			BasicNetworkPacket* packet = get_rb_data_data<BasicNetworkPacket>(object);

			packet->type = rb_parse_int(type_value);

			return type_value;
		}

		static RubyValue __cdecl get_from_id_ruby(RubyValue object) {
			BasicNetworkPacket* packet = get_rb_data_data<BasicNetworkPacket>(object);

			return rb_i642num(packet->from_id);
		}

		static RubyValue __cdecl set_from_id_ruby(RubyValue object, RubyValue from_id_value) {
			BasicNetworkPacket* packet = get_rb_data_data<BasicNetworkPacket>(object);

			packet->from_id = rb_num2ull(from_id_value);

			return from_id_value;
		}

		static RubyValue __cdecl get_data_ruby(RubyValue object) {
			BasicNetworkPacket* packet = get_rb_data_data<BasicNetworkPacket>(object);

			return rb_str_new_cstr(packet->data.c_str());
		}

		static RubyValue __cdecl set_data_ruby(RubyValue object, RubyValue data_value) {
			BasicNetworkPacket* packet = get_rb_data_data<BasicNetworkPacket>(object);

			RubyValue data_value_orig = data_value;
			packet->data = rb_get_string_data(&data_value);

			return data_value_orig;
		}

		std::string to_raw_data() {
			std::ostringstream raw_data;
			union {
				struct {
					uint32_t high;
					uint32_t low;
				} bigint;
				uint64_t number;
			} from_id_u;
			from_id_u.number = from_id;

			raw_data.write(reinterpret_cast<const char*>(&BasicNetworkPacket::magic), sizeof(BasicNetworkPacket::magic));
			raw_data.write(reinterpret_cast<const char*>(&type), sizeof(type));
			raw_data.write(reinterpret_cast<const char*>(&from_id_u.bigint.high), sizeof(from_id_u.bigint.high));
			raw_data.write(reinterpret_cast<const char*>(&from_id_u.bigint.low), sizeof(from_id_u.bigint.low));
			raw_data.write(data.c_str(), data.length());

			return std::move(raw_data).str();
		}

		bool from_raw_data(std::span<const char> raw_data) {
			debug_mod_loader_log("Got packet with size: {}\n", raw_data.size());

			const size_t header_size = sizeof(BasicNetworkPacket::magic) + sizeof(type) + sizeof(from_id);
			if (raw_data.size() < header_size) {
				return false;
			}

			union {
				struct {
					uint32_t high;
					uint32_t low;
				} bigint;
				uint64_t number;
			} from_id_u;
			std::streamoff offset = 0;
			
			std::remove_const_t<decltype(BasicNetworkPacket::magic)> data_magic;
			memcpy(reinterpret_cast<char*>(&data_magic), raw_data.data() + offset, sizeof(data_magic));
			offset += sizeof(data_magic);
			debug_mod_loader_log("Packet magic: 0x{:X}\n", data_magic);
			if (data_magic != BasicNetworkPacket::magic) {
				return false;
			}

			memcpy(reinterpret_cast<char*>(&type), raw_data.data() + offset, sizeof(type));
			offset += sizeof(type);
			memcpy(reinterpret_cast<char*>(&from_id_u.bigint.high), raw_data.data() + offset, sizeof(from_id_u.bigint.high));
			offset += sizeof(from_id_u.bigint.high);
			memcpy(reinterpret_cast<char*>(&from_id_u.bigint.low), raw_data.data() + offset, sizeof(from_id_u.bigint.low));
			offset += sizeof(from_id_u.bigint.low);
			from_id = from_id_u.number;
			data.resize(raw_data.size() - header_size);
			memcpy(data.data(), raw_data.data() + offset, data.length());

			debug_mod_loader_log("Type: {}, from_id: {}, data: {} ({})\n", type, from_id, data, data.length());

			return true;
		}
	};

	RubyValue BasicNetworkPacket::klass = 0;

	struct SteamAPI {
		static RubyValue klass;

		static RubyValue __cdecl create_lobby_ruby(RubyValue object, RubyValue type_value, RubyValue max_players_value, RubyValue callback_value) {
			if (!check_ruby_type(type_value, RUBY_T_FIXNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected type as fixnum");
				return ruby_nil;
			}
			if (!check_ruby_type(max_players_value, RUBY_T_FIXNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected max_players as fixnum");
				return ruby_nil;
			}
			//debug_mod_loader_log(
			//	"callback type: {}, callback klass: {}, call result klass: {}",
			//	static_cast<int>(rb_type(callback_value)),
			//	check_ruby_type(callback_value, RUBY_T_DATA) ? dynamic_cast<SteamCCallResult*>(get_rb_data_data<CCallbackBase>(callback_value)) : 0,
			//	SteamCCallResult::klass
			//);
			//if (callback_value != ruby_nil && (!check_ruby_type(callback_value, RUBY_T_DATA) || rb_get_value_klass(callback_value) != SteamCCallResult::klass)) {
			//	rb_raise(*ruby_error_arg_error, "Expected callback as SteamCCallResult or nil");
			//	return ruby_nil;
			//}

			ELobbyType lobby_type = static_cast<ELobbyType>(rb_parse_int(type_value));
			int max_players = rb_parse_int(max_players_value);

			ISteamMatchmaking* matchmaking = SteamMatchmaking();
			SteamAPICall_t api_call = SteamMatchmaking()->CreateLobby(lobby_type, max_players);
			debug_mod_loader_log("SteamAPI create_lobby. Matchmaking: {:X}, api_call: {}\n",
				reinterpret_cast<uintptr_t>(matchmaking),
				api_call
			);
			if (callback_value != ruby_nil) {
				SteamCCallResult* callback = get_rb_data_data<SteamCCallResult>(callback_value);
				callback->set_api_call(api_call);
			}

			return callback_value;
		}

		static RubyValue __cdecl leave_lobby(RubyValue object, RubyValue lobby_id_value) {
			if (!check_ruby_type(lobby_id_value, RUBY_T_FIXNUM, RUBY_T_BIGNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected lobby_id as fixnum or bignum");
				return ruby_nil;
			}

			CSteamID steam_id = rb_num2ull(lobby_id_value);
			SteamMatchmaking()->LeaveLobby(steam_id);
			return ruby_true;
		}

		static RubyValue __cdecl join_lobby_ruby(RubyValue object, RubyValue lobby_id_value, RubyValue callback_value) {
			if (callback_value == ruby_nil) {
				// ...
				return ruby_nil;
			}
			if (!check_ruby_type(lobby_id_value, RUBY_T_FIXNUM, RUBY_T_BIGNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected lobby_id as fixnum or bignum");
				return ruby_nil;
			}
			SteamCCallResult* callback = get_rb_data_data<SteamCCallResult>(callback_value);
			CSteamID lobby_id = rb_num2ull(lobby_id_value);

			SteamAPICall_t api_call = SteamMatchmaking()->JoinLobby(lobby_id);
			callback->set_api_call(api_call);

			return callback_value;
		}

		static RubyValue __cdecl get_lobby_owner_ruby(RubyValue object, RubyValue lobby_id_value) {
			if (!check_ruby_type(lobby_id_value, RUBY_T_FIXNUM, RUBY_T_BIGNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected lobby_id as fixnum or bignum");
				return ruby_nil;
			}
			CSteamID lobby_id = rb_num2ull(lobby_id_value);

			CSteamID owner_id = SteamMatchmaking()->GetLobbyOwner(lobby_id);

			if (!owner_id.IsValid()) {
				return ruby_nil;
			}
			return rb_i642num(owner_id.ConvertToUint64());
		}

		static RubyValue __cdecl send_message_to_user_ruby(RubyValue object, RubyValue user_id_value, RubyValue channel_value, RubyValue data_value, RubyValue flags_value) {
			if (false) {
				rb_raise(*ruby_error_arg_error, "Wrong arguments");
				return ruby_nil;
			}
			SteamNetworkingIdentity identity;
			identity.SetSteamID64(rb_num2ull(user_id_value));
			int channel_id = rb_parse_int(channel_value);
			int flags = rb_parse_int(flags_value);
			std::string_view data = rb_get_string_data(&data_value);

			debug_mod_loader_log("SteamAPI send message to {}, data: {}\n", identity.GetSteamID64(), data);
			EResult result = SteamNetworkingMessages()->SendMessageToUser(identity, data.data(), data.size(), flags | k_nSteamNetworkingSend_AutoRestartBrokenSession, channel_id);

			SteamNetConnectionInfo_t conn_info;
			SteamNetConnectionRealTimeStatus_t real_conn_info;
			ESteamNetworkingConnectionState conn_state = SteamNetworkingMessages()->GetSessionConnectionInfo(identity, &conn_info, &real_conn_info);

			debug_mod_loader_log("SteamAPI send result: {}. Connection state: {}\n",
				static_cast<int>(result),
				static_cast<int>(conn_state)
			);

			return ruby_true;
		}

		static RubyValue __cdecl read_messages_on_channel_ruby(RubyValue object, RubyValue channel_value, RubyValue max_messages_value, RubyValue recv, RubyValue method_value) {
			if (false) {
				rb_raise(*ruby_error_arg_error, "Wrong arguments");
				return ruby_nil;
			}
			int channel_id = rb_parse_int(channel_value);
			int max_messages = rb_parse_int(max_messages_value);
			RubyID method = rb_sym2id(method_value);

			constexpr int internal_max_messages = 10;
			SteamNetworkingMessage_t* messages[internal_max_messages];
			int message_count = SteamNetworkingMessages()->ReceiveMessagesOnChannel(channel_id, messages, std::min(internal_max_messages, max_messages));

			debug_mod_loader_log("SteamAPI read messages: got {} messages\n", message_count);
			for (int i = 0; i < message_count; ++i) {
				uint64_t user_id = messages[i]->m_identityPeer.GetSteamID64();
				std::string message_data(static_cast<const char*>(messages[i]->GetData()), messages[i]->GetSize());
				rb_funcall(recv, method, 2,
					rb_i642num(user_id),
					rb_str_new_cstr(message_data.data())
				);

				messages[i]->Release();
			}

			return ruby_true;
		}

		static RubyValue __cdecl send_basic_packet_ruby(RubyValue object, RubyValue user_id_value, RubyValue channel_value, RubyValue packet_value, RubyValue flags_value) {
			if (!check_ruby_type(user_id_value, RUBY_T_FIXNUM, RUBY_T_BIGNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected user_id as fixnum or bignum");
				return ruby_nil;
			}
			if (!check_ruby_type(channel_value, RUBY_T_FIXNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected channel as fixnum");
				return ruby_nil;
			}
			if (!check_ruby_type(flags_value, RUBY_T_FIXNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected flags as fixnum");
				return ruby_nil;
			}

			SteamNetworkingIdentity identity;
			identity.SetSteamID64(rb_num2ull(user_id_value));
			int channel_id = rb_parse_int(channel_value);
			int flags = rb_parse_int(flags_value);
			BasicNetworkPacket* packet = get_rb_data_data<BasicNetworkPacket>(packet_value);

			std::string raw_data_string = packet->to_raw_data();
			// debug_mod_loader_log("Sending packet: {}", raw_data_string);

			EResult result = SteamNetworkingMessages()->SendMessageToUser(
				identity,
				raw_data_string.c_str(),
				raw_data_string.size(),
				k_nSteamNetworkingSend_AutoRestartBrokenSession | flags,
				channel_id
			);

			return result == k_EResultOK ? ruby_true : ruby_false;
		}

		static void process_packet(BasicNetworkPacket& packet, RubyValue recv, RubyID method) {

		}

		static RubyValue __cdecl read_basic_packets_ruby(RubyValue object, RubyValue channel_value, RubyValue max_messages_value, RubyValue recv, RubyValue method_value) {
			if (!check_ruby_type(channel_value, RUBY_T_FIXNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected channel as fixnum");
				return ruby_nil;
			}
			if (!check_ruby_type(max_messages_value, RUBY_T_FIXNUM)) {
				rb_raise(*ruby_error_arg_error, "Expected max_messages as fixnum");
				return ruby_nil;
			}
			if (!check_ruby_type(method_value, RUBY_T_SYMBOL)) {
				rb_raise(*ruby_error_arg_error, "Expected method as symbol");
				return ruby_nil;
			}

			int channel_id = rb_parse_int(channel_value);
			int max_messages = rb_parse_int(max_messages_value);
			RubyID method = rb_sym2id(method_value);

			constexpr int internal_max_messages = 10;
			SteamNetworkingMessage_t* messages[internal_max_messages];
			int message_count = SteamNetworkingMessages()->ReceiveMessagesOnChannel(channel_id, messages, std::min(internal_max_messages, max_messages));
			
			RubyValue reusable_packet_value = BasicNetworkPacket::alloc(BasicNetworkPacket::klass);
			BasicNetworkPacket* reusable_packet = get_rb_data_data<BasicNetworkPacket>(reusable_packet_value);
			for (int i = 0; i < message_count; ++i) {
				SteamNetworkingMessage_t* message = messages[i];

				const char* raw_data = reinterpret_cast<const char*>(message->GetData());
				std::stringstream buffer;
				buffer << "Packet data: [";
				for (int i = 0; i < message->GetSize(); ++i) {
					char byte = raw_data[i];
					buffer << std::hex << static_cast<uint16_t>(byte) << ", ";
				}
				buffer << "]\n";
				debug_mod_loader_log("{}", buffer.str());

				reusable_packet->from_raw_data(std::span(raw_data, raw_data + message->GetSize()));
				rb_funcall(recv, method, 2,
					rb_i642num(message->m_identityPeer.GetSteamID64()),
					reusable_packet_value
				);
				
				message->Release();
			}

			return ruby_true;
		}
	};

	RubyValue SteamAPI::klass = 0;

	template<typename T>
	T get_proc_as(HMODULE module, const char* name) {
		return reinterpret_cast<T>(GetProcAddress(module, name));
	}

	void init_rb_steam_callresult() {
		if (SteamCCallResult::klass) {
			return;
		}
		SteamCCallResult::klass = rb_define_class("SteamCCallResult", *ruby_c_object);
		rb_define_alloc_func(SteamCCallResult::klass, &SteamCCallResult::alloc);
		rb_define_method(SteamCCallResult::klass, "initialize", &SteamCCallResult::initialize, 1);
		rb_define_method(SteamCCallResult::klass, "set", &SteamCCallResult::set_ruby, 3);
		rb_define_method(SteamCCallResult::klass, "register", &SteamCCallResult::register_ruby, 2);
	}

	void init_rb_steam_callback() {
		if (SteamCCallback::klass) {
			return;
		}
		SteamCCallback::klass = rb_define_class("SteamCCallback", *ruby_c_object);
		rb_define_alloc_func(SteamCCallback::klass, &SteamCCallback::alloc);
		rb_define_method(SteamCCallback::klass, "initialize", &SteamCCallback::initialize, 3);
		rb_define_method(SteamCCallback::klass, "register", &SteamCCallback::register_ruby, 2);
	}

	void init_rb_basic_network_packet() {
		if (BasicNetworkPacket::klass) {
			return;
		}
		BasicNetworkPacket::klass = rb_define_class("BasicNetworkPacket", *ruby_c_object);
		rb_define_alloc_func(BasicNetworkPacket::klass, &BasicNetworkPacket::alloc);
		rb_define_method(BasicNetworkPacket::klass, "initialize", &BasicNetworkPacket::initialize, 3);
		rb_define_method(BasicNetworkPacket::klass, "type", &BasicNetworkPacket::get_type_ruby, 0);
		rb_define_method(BasicNetworkPacket::klass, "type=", &BasicNetworkPacket::set_type_ruby, 1);
		rb_define_method(BasicNetworkPacket::klass, "from_id", &BasicNetworkPacket::get_from_id_ruby, 0);
		rb_define_method(BasicNetworkPacket::klass, "from_id=", &BasicNetworkPacket::set_from_id_ruby, 1);
		rb_define_method(BasicNetworkPacket::klass, "data", &BasicNetworkPacket::get_data_ruby, 0);
		rb_define_method(BasicNetworkPacket::klass, "data=", &BasicNetworkPacket::set_data_ruby, 1);
	}

	void init_rb_steam_api() {
		SteamAPI::klass = rb_define_module("SteamAPI");
		rb_define_singleton_method(SteamAPI::klass, "create_lobby", &SteamAPI::create_lobby_ruby, 3);
		rb_define_singleton_method(SteamAPI::klass, "leave_lobby", &SteamAPI::leave_lobby, 1);
		rb_define_singleton_method(SteamAPI::klass, "join_lobby", &SteamAPI::join_lobby_ruby, 2);
		rb_define_singleton_method(SteamAPI::klass, "get_lobby_owner", &SteamAPI::get_lobby_owner_ruby, 1);

		rb_define_singleton_method(SteamAPI::klass, "send_message_to_user", &SteamAPI::send_message_to_user_ruby, 4);
		rb_define_singleton_method(SteamAPI::klass, "read_messages_on_channel", &SteamAPI::read_messages_on_channel_ruby, 4);
		rb_define_singleton_method(SteamAPI::klass, "send_basic_packet", &SteamAPI::send_basic_packet_ruby, 4);
		rb_define_singleton_method(SteamAPI::klass, "read_basic_packets", &SteamAPI::read_basic_packets_ruby, 4);
	}

	bool init_steam_env() {
		if (!(steam_api_module = LoadLibrary(TEXT("steam_api.dll"))))
			return false;

		if (!(SteamAPI_GetHSteamUser = get_proc_as<decltype(SteamAPI_GetHSteamUser)>(steam_api_module, "SteamAPI_GetHSteamUser")))
			return false;
		if (!(SteamAPI_FindOrCreateUserInterface = get_proc_as<decltype(SteamAPI_FindOrCreateUserInterface)>(steam_api_module, "SteamInternal_FindOrCreateUserInterface")))
			return false;

		if (!(SteamAPI_RegisterCallback = get_proc_as<decltype(SteamAPI_RegisterCallback)>(steam_api_module, "SteamAPI_RegisterCallback")))
			return false;
		if (!(SteamAPI_UnregisterCallback = get_proc_as<decltype(SteamAPI_UnregisterCallback)>(steam_api_module, "SteamAPI_UnregisterCallback")))
			return false;

		if (!(SteamAPI_RegisterCallResult = get_proc_as<decltype(SteamAPI_RegisterCallResult)>(steam_api_module, "SteamAPI_RegisterCallResult")))
			return false;
		if (!(SteamAPI_UnregisterCallResult = get_proc_as<decltype(SteamAPI_RegisterCallResult)>(steam_api_module, "SteamAPI_UnregisterCallResult")))
			return false;

		return true;
	}

	void apply_steam_support_hooks() {
		auto config_value = mod_loader->get_config().get("steam_support");
		if (!config_value || !config_value->get<bool>()) {
			return;
		}

		mod_loader->add_preinit_handler([] {
			if (!init_steam_env()) {
				mod_loader->log_error("Failed to init steam environment!\n");
				return;
			}
			init_rb_steam_api();
			init_rb_steam_callresult();
			init_rb_basic_network_packet();
			init_rb_steam_callback();
		});

		mod_loader->log_info("Applied steam support\n");
	}
}