#include "GLFWMisc.hpp"

#include <GLFW/glfw3.h>
#include <mutex>

namespace rm_modloader {
	int init_glfw() {
		static std::once_flag init_flag;
		static int init_ret = GLFW_FALSE;
		std::call_once(init_flag, [] {
			init_ret = glfwInit();
		});
		
		return init_ret;
	}
}