#pragma once
#include "minhook.h"
#include <typeinfo>
#include <bit>

/**
 * Get original class pointer from offsetted pointer to it's member
 */
#ifndef container_of
# define container_of(ptr, s, c) (reinterpret_cast<s*>(reinterpret_cast<char const volatile*>(ptr) - offsetof(s, c)))
#endif

/**
 * Structure containing object pointer and member method.
 * Used to call bound method just by calling it. Used in @ref bind_vftable
 * @tparam T child class type
 * @tparam TMethod VFTable method type
 */
template<typename T, typename TMethod>
struct ThisBoundMethod {

    /**
     * Calls bound method
     * @tparam TArgs The bound method arguments types
     * @param args ... The bound method arguments
     */
    template<typename ... TArgs>
    //requires requires (TArgs&& ... args) { (object->*method)(std::forward<TArgs...>(args) ...); }
    decltype(auto) operator()(TArgs&& ... args) {
        return (object->*method)(std::forward<TArgs>(args) ...);
    }

    T* object;
    TMethod method;
};

/**
 * Casts this object base VFTable (virtual functions table) to child's VFTable
 * @tparam T child class type
 * @tparam TVFTable child's VFTable type
 * @param object 'this' pointer
 * @return Pointer to child's VFTable
 */
template<typename T, typename TVFTable = typename T::VFTable>
[[nodiscard]] constexpr TVFTable* cast_vftable(T* object) noexcept {
    return static_cast<TVFTable*>(object->vftable);
}

/**
 * Casts this object base VFTable (virtual functions table) and binds member bound method
 * @tparam T child class type
 * @tparam TMethod VFTable method type
 * @param object 'this' pointer
 * @param method Pointer to member method of 'T' VFTable
 * @return VFTable bound method. Can be used to call actual method
 */
template<typename T, typename TMethod>
[[nodiscard]] constexpr auto bind_vftable(T* object, TMethod method) noexcept {
    return ThisBoundMethod{ object, cast_vftable(object)->*method };
}

///**
// * 
// */
//template<typename T, typename TVFTable, typename TMethod, typename THookMethod>
//auto patch_vftable(TVFTable* vftable, TMethod TVFTable::* T::* method, THookMethod T::* hook_method) {
//    
//}

/**
 * Get pointer to address with offset from base in bytes (base + offset)
 * @tparam T Returned pointer type
 * @param base Base address
 * @param offset Offset from base in bytes
 * @return Offsetted address pointer
 */
template<typename T>
[[nodiscard]] inline T at_offset(void* base, intptr_t offset) noexcept {
    return std::bit_cast<T>(reinterpret_cast<char*>(base) + offset);
}

/**
 * Get value at address with offset in bytse
 * @tparam T Returned pointer type
 * @param base Base address
 * @param offset Offset from base in bytes
 * @return Value at offsetted address
 */
template<typename T>
[[nodiscard]] inline T& at_address(void* base, intptr_t offset) noexcept {
    return *at_offset<std::add_pointer_t<T>>(base, offset);
}

///**
// * Get value at address
// * @tparam T Returned pointer type
// * @param base Base address
// * @param offset Offset from base in bytes
// * @return Value at address
// */
//template<typename T>
//[[nodiscard]] inline T& at_address(void* base) {
//    return *reinterpret_cast<std::add_pointer_t<T>>(base);
//}

/**
 * Structure holding information about virtual class. Located right before vftable
 */
struct RTTIObjectLocator {
    const DWORD signature;
    const DWORD vftable_offset;
    const DWORD ctx_displacement_offset;
    const std::type_info* type_info;
    const void* hierarchy_reference;
};

static_assert(offsetof(RTTIObjectLocator, signature) == 0x0);
static_assert(offsetof(RTTIObjectLocator, vftable_offset) == 0x4);
static_assert(offsetof(RTTIObjectLocator, ctx_displacement_offset) == 0x8);
static_assert(offsetof(RTTIObjectLocator, type_info) == 0xC);
static_assert(offsetof(RTTIObjectLocator, hierarchy_reference) == 0x10);
static_assert(sizeof(RTTIObjectLocator) == 0x14);

/**
 * Get @ref RTTIObjectLocator from pointer to virtual class containing it's information. *Unsafe*
 * @param object Pointer to virtual class
 * @return The class object locator
 */
[[nodiscard]] inline RTTIObjectLocator* get_object_locator(void* object) noexcept {
    static constexpr intptr_t rtti_offset = -static_cast<intptr_t>(sizeof(void*));
    void* vftable = at_address<void*>(object, 0);
    return at_address<RTTIObjectLocator*>(vftable, rtti_offset);
}

/**
 * Check if a given virtual object is a given class
 * @return true if object is that class, false otherwise
 */
template<typename T>
    requires requires { T::type_name; }
[[nodiscard]] inline bool is_vlocation(const RTTIObjectLocator* loc) noexcept {
    if (!loc || !loc->type_info) return false;
    return loc->type_info->name() == T::type_name;
}

template<typename T>
    requires requires { T::type_name; }
[[nodiscard]] inline bool is_vclass(const void* object) noexcept {
    if (!object) return false;
    return is_vlocation<T>(get_object_locator(const_cast<void*>(object)));
}