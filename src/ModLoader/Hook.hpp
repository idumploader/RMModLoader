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
[[nodiscard]] constexpr TVFTable* cast_vftable(T* object) {
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
[[nodiscard]] constexpr auto bind_vftable(T* object, TMethod method) {
    return ThisBoundMethod{ object, cast_vftable(object)->*method };
}

/**
 * Get pointer to address with offset from base in bytes (base + offset)
 * @tparam T Returned pointer type
 * @param base Base address
 * @param offset Offset from base in bytes
 * @return Offsetted address pointer
 */
template<typename T>
[[nodiscard]] inline T at_offset(void* base, intptr_t offset) {
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
[[nodiscard]] inline T& at_address(void* base, intptr_t offset) {
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

static_assert(offsetof(RTTIObjectLocator, type_info) == 0xC);

/**
 * Get @ref RTTIObjectLocator from pointer to virtual class containing it's information. *Unsafe*
 * @param object Pointer to virtual class
 * @return The class object locator
 */
inline RTTIObjectLocator* get_object_locator(void* object) {
    return at_address<RTTIObjectLocator*>(at_address<void*>(object, 0), -intptr_t(sizeof(void*)));
}