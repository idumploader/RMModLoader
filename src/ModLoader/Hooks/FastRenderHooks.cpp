// FastRenderHooks is a work-in-progress experiment; its warnings (including
// those from template instantiations it triggers in STL / StapleGL headers)
// are silenced wholesale until it stabilizes. Remove this push/pop when the
// file is productionized.
#pragma warning(push, 0)
// Disable specific codes by number too: STL headers do their own
// #pragma warning(push, 3) which overrides the level-based push,0 above, but
// the per-number disabled-list survives it (suppresses header-origin template
// instantiation warnings: C4244/C4834 from emplace_back / std::optional).
#pragma warning(disable: 4244 4267 4018 4834)

#include "FastRenderHooks.hpp"
#include "../ModLoader.hpp"
#include "../TilemapReader.hpp"
#include "../Hook.hpp"

#include <glad.h>
#include <staplegl.hpp>
#include <GLFW/glfw3.h>
#include <glm/glm.hpp>
#include <glm/ext.hpp>

#include <thread>
#include <map>
#include <ranges>
#include <queue>
#include <set>

template<typename T, typename ... TArgs> requires (std::convertible_to<T, TArgs> && ...)
constexpr auto make_array(T&& first, TArgs&& ... args) {
	return std::array<std::remove_reference_t<T>, sizeof...(TArgs) + 1> {
		std::forward<T>(first), T(std::forward<TArgs>(args)) ...
	};
}

template<typename T>
std::array<T, 0> make_array() {
	return {};
}

using std::views::iota;

namespace rm_modloader {

	constexpr int32_t max_z_layer = 100;

	static RxTilemap* current_tilemap = nullptr;
	static bool changed_surface = false;

	GLuint check_shader(const staplegl::shader& checked_shader) {
		GLuint shader = glCreateShader(checked_shader.type == staplegl::shader_type::fragment ? GL_FRAGMENT_SHADER : GL_VERTEX_SHADER);
		const char* shaderSource = checked_shader.source.c_str();
		glShaderSource(shader, 1, &shaderSource, NULL);
		glCompileShader(shader);

		int is_tilemap_compiled = false;
		glGetShaderiv(shader, GL_COMPILE_STATUS, &is_tilemap_compiled);
		if (!is_tilemap_compiled) {
			int max_length = 0;
			glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &max_length);
			std::string error_log(max_length, '\0');
			glGetShaderInfoLog(shader, max_length, &max_length, &error_log[0]);

			mod_loader->log_info("Failed to compile shader: {}\n", error_log);
		}

		return shader;
	}

	void check_shader_program(const staplegl::shader_program& program) {
		GLuint shader_1 = check_shader(program[0]);
		GLuint shader_2 = check_shader(program[1]);

		GLuint shader_program = glCreateProgram();
		glAttachShader(shader_program, shader_1);
		glAttachShader(shader_program, shader_2);
		glLinkProgram(shader_program);

		GLint  success = true;
		glGetProgramiv(shader_program, GL_LINK_STATUS, &success);
		if (!success) {
			int max_length = 0;
			glGetProgramiv(shader_program, GL_INFO_LOG_LENGTH, &max_length);
			std::string error_log_link(max_length, '\0');
			glGetProgramInfoLog(shader_program, max_length, &max_length, &error_log_link[0]);

			mod_loader->log_info("Failed to link shader: {}\n", error_log_link);
		}
	}

#pragma pack(push, 4)
	struct TileRenderPrimitive {

		TileRenderPrimitive(glm::vec3 offset, glm::vec2 zoom, glm::vec2 tex_offset, float tex_index, glm::vec2 anim_stride = glm::vec2(0.0f, 0.0f));

		static staplegl::vertex_buffer_layout get_layout() {
			return staplegl::vertex_buffer_layout {
				{ staplegl::shader_data_type::u_type::vec3, "aOffset" },
				{ staplegl::shader_data_type::u_type::vec2, "aZoom" },
				{ staplegl::shader_data_type::u_type::vec2, "aTexOffset" },
				{ staplegl::shader_data_type::u_type::float32, "aTexIndex" },
				{ staplegl::shader_data_type::u_type::vec2, "aAnimStride" },
			};
		}

		glm::vec3 offset;
		glm::vec2 zoom;
		glm::vec2 texture_offset;
		float texture_index;
		glm::vec2 animation_stride;
	};

	struct SpriteRenderPrimitive {

		SpriteRenderPrimitive() = default;
		SpriteRenderPrimitive(glm::vec3 offset, glm::vec2 zoom, glm::vec2 texture_offset, glm::vec2 texture_size, GLuint64 texture_handle, float opacity);

		inline static staplegl::vertex_buffer_layout get_layout() {
			return staplegl::vertex_buffer_layout{
				{ staplegl::shader_data_type::u_type::vec3, "aOffset" },
				{ staplegl::shader_data_type::u_type::vec2, "aZoom" },
				{ staplegl::shader_data_type::u_type::vec2, "aTexOffset" },
				{ staplegl::shader_data_type::u_type::vec2, "aTexSize" },
				{ staplegl::shader_data_type::u_type::vec2, "aTexHandle" },
				{ staplegl::shader_data_type::u_type::float32, "aOpacity" },
			};
		}

		glm::vec3 offset;
		glm::vec2 zoom;
		glm::vec2 texture_offset;
		glm::vec2 texture_size;
		GLuint64 texture_handle;
		float opacity;
	};

#pragma pack(pop)

	class TilePrimitivesReader : public tilemap::TilemapReader {
	public:
		TilePrimitivesReader() = default;
		TilePrimitivesReader(const RxTilemap* tilemap, int z_offset);
		TilePrimitivesReader(const TilePrimitivesReader& other) = default;
		TilePrimitivesReader(TilePrimitivesReader&& other) = default;
		~TilePrimitivesReader() = default;

		TilePrimitivesReader& operator=(const TilePrimitivesReader& other) = default;
		TilePrimitivesReader& operator=(TilePrimitivesReader&& other) = default;

		std::span<const float> data_span() const;
		size_t instance_count() const;

	private:
		void on_primitive(const glm::vec3& origin, const glm::vec2& zoom, const glm::vec2& tex_offset, int texture_index, const glm::vec2& animation_stride) override;

		void on_shadow_primitive(const glm::vec3& origin, const glm::vec2& tex_offset) override;

		std::vector<TileRenderPrimitive> tile_primitives_;
	};

	class TilemapRenderContext {
	public:
		static constexpr int max_textures = 9;
		static constexpr int shadow_texture_index = 9;
		static staplegl::texture_2d shadow_texture;

		static staplegl::texture_2d make_shadow_texture();

		TilemapRenderContext(RxTilemap* tilemap);
		TilemapRenderContext(const TilemapRenderContext& other) = default;
		TilemapRenderContext(TilemapRenderContext&& other) = default;
		~TilemapRenderContext() = default;

		void emplace_data_from(RxTilemap* tilemap);
		void emplace_texture(RxTilemap* tilemap, int index);
		void emplace_all_textures(RxTilemap* tilemap);

		void bind_all_textures_to(staplegl::shader_program& shader);

		std::array<staplegl::texture_2d, max_textures> textures;
		staplegl::vertex_array vao;
		size_t instances_count;
		const size_t render_width;
		const size_t render_height;
	};

	//struct SpritesRenderContext {
	//
	//	SpritesRenderContext() = default;
	//	SpritesRenderContext(const SpritesRenderContext& other) = default;
	//	SpritesRenderContext(SpritesRenderContext&& other) = default;
	//	~SpritesRenderContext() = default;
	//
	//	void add_sprite();
	//	void update_sprite_texture();
	//	void update_sprite();
	//	void remove_sprite();
	//
	//	void update_pending();
	//
	//	size_t instance_count();
	//
	//	staplegl::vertex_array vao;
	//	std::map<RxSprite*, int> vao_sprites;
	//	std::queue<RxSprite*> updated_sprites;
	//};

	struct SpriteRenderContext {
		int vao_index;
		RxSprite* sprite;
		SpriteRenderPrimitive primitive;
	};

	class GLRenderer {
	public:
		static constexpr int32_t max_z_layer = 300;
		static constexpr std::string_view shaders_subpath = "shaders";
		static constexpr std::chrono::duration animation_delta = std::chrono::milliseconds(500);

		GLRenderer(GLFWwindow* window, int width, int height);
		GLRenderer(const GLRenderer& other) = delete;
		GLRenderer(GLRenderer&& other) = default;
		~GLRenderer();

		void add_tilemap_context(RxTilemap* tilemap);
		void on_tilemap_changed_data(RxTilemap* tilemap);
		void on_tilemap_changed_tileset(RxTilemap* tilemap, int index);
		void on_tilemap_destroyed(RxTilemap* tilemap);

		void render_screen(Screen* screen);
		void render_sprites(Screen* screen);
		void render_tilemap(Screen* screen);

		void poll() const;

		std::optional<SpriteRenderPrimitive> make_sprite_primitive(RxSprite* sprite);
		void on_sprite_constructed(RxSprite* sprite);
		void on_sprite_updated(RxSprite* sprite);
		void on_sprite_updated_texture(RxSprite* sprite);
		void on_sprite_destructed(RxSprite* sprite);

		void on_surface_changed(Surface* surface);
		void on_surface_destructed(Surface* surface);

		// initializes OpenGL, very important to call this before any opengl calls or staplegl object creation
		static GLFWwindow* make_window(int width, int height);

	private:

		static void glfw_key_callback(GLFWwindow* window, int key, int scancode, int action, int mods);

		inline static staplegl::vertex_buffer_layout make_vbo_layout() {
			return staplegl::vertex_buffer_layout {
				{ staplegl::shader_data_type::u_type::vec3, "aPos" },
				{ staplegl::shader_data_type::u_type::vec2, "aTexCoord" },
			};
		}

		inline static staplegl::vertex_buffer_layout make_tilemap_layout() {
			return TileRenderPrimitive::get_layout();
		}

		inline static staplegl::vertex_buffer_layout make_sprites_layout() {
			return SpriteRenderPrimitive::get_layout();
		}

		static bool glad_inited_;

		GLFWwindow* window_;

		staplegl::shader_program tilemap_shader_;
		staplegl::shader_program sprites_shader_;
		std::map<RxTilemap*, TilemapRenderContext> tilemap_contexts_;

		static const std::array<float, 20> rect_vertices_;
		static const std::array<unsigned int, 6> rect_indices_;
		const int window_width_;
		const int window_height_;
		const std::chrono::high_resolution_clock::time_point initial_time_;

		staplegl::vertex_array sprites_vao_;
		std::map<RxSprite*, int> sprite_context_indices_;
		std::vector<SpriteRenderContext> sprite_contexts_;
		std::queue<RxSprite*> updated_sprites_;

		std::map<Surface*, staplegl::texture_2d> surface_textures_;
	};

	staplegl::texture_2d TilemapRenderContext::shadow_texture;

	bool GLRenderer::glad_inited_ = false;

	constexpr std::array<float, 20> GLRenderer::rect_vertices_ = {
		// position    z    tex coords 
		32.0f, 0.0f , 0.0f, 1.0f, 1.0f, // top right
		32.0f, 32.0f, 0.0f, 1.0f, 0.0f, // bottom right
		0.0f , 32.0f, 0.0f, 0.0f, 0.0f, // bottom left
		0.0f , 0.0f , 0.0f, 0.0f, 1.0f, // top left
	};

	constexpr std::array<unsigned int, 6> GLRenderer::rect_indices_ = {
		0, 1, 3, // first Triangle
		1, 2, 3  // second Triangle
	};

	std::shared_ptr<GLRenderer> shared_renderer = nullptr;

	inline std::span<const float> tile_value_ptr(std::span<const TileRenderPrimitive> primitives) {
		return std::span<const float>(glm::value_ptr(primitives[0].offset), primitives.size_bytes() / sizeof(float));
	}

	inline std::span<const float> sprite_value_ptr(const SpriteRenderPrimitive& primitive) {
		return std::span<const float>(glm::value_ptr(primitive.offset), sizeof(SpriteRenderPrimitive) / sizeof(float));
	}

	TileRenderPrimitive::TileRenderPrimitive(glm::vec3 offset, glm::vec2 zoom, glm::vec2 tex_offset, float tex_index, glm::vec2 anim_stride) :
		offset(std::move(offset)),
		zoom(std::move(zoom)),
		texture_offset(std::move(tex_offset)),
		texture_index(tex_index),
		animation_stride(anim_stride)
	{}

	TilePrimitivesReader::TilePrimitivesReader(const RxTilemap* tilemap, int z_offset) {
		tile_primitives_.reserve(tilemap->width * tilemap->height * tilemap->depth);
		tilemap::read_tilemap_primitives(*this, tilemap, z_offset);
	}

	SpriteRenderPrimitive::SpriteRenderPrimitive(glm::vec3 offset, glm::vec2 zoom, glm::vec2 texture_offset, glm::vec2 texture_size, GLuint64 texture_handle, float opacity) :
		offset(std::move(offset)),
		zoom(std::move(zoom)),
		texture_offset(std::move(texture_offset)),
		texture_size(std::move(texture_size)),
		texture_handle(std::move(texture_handle)),
		opacity(opacity)
	{}

	std::span<const float> TilePrimitivesReader::data_span() const {
		return tile_value_ptr(tile_primitives_);
	}

	size_t TilePrimitivesReader::instance_count() const {
		return tile_primitives_.size();
	}

	void TilePrimitivesReader::on_primitive(const glm::vec3& origin, const glm::vec2& zoom, const glm::vec2& tex_offset, int texture_index, const glm::vec2& animation_stride) {
		tile_primitives_.emplace_back(origin, zoom, tex_offset, texture_index, animation_stride);
	}
	
	void TilePrimitivesReader::on_shadow_primitive(const glm::vec3& origin, const glm::vec2& tex_offset) {
		tile_primitives_.emplace_back(origin, glm::vec2(1.f), tex_offset, TilemapRenderContext::shadow_texture_index, glm::vec2(0.f));
	}

	staplegl::texture_2d TilemapRenderContext::make_shadow_texture() {
		// y-flipped shadow quaters
		constexpr std::array<char[8], 8> opaque_quaters = {
			1, 1, 1, 1, 1, 1, 1, 1,
			0, 0, 1, 0, 0, 1, 1, 1,
			0, 1, 0, 1, 0, 1, 0, 1,
			0, 0, 1, 0, 0, 1, 1, 1,
			1, 0, 1, 0, 1, 0, 1, 0,
			0, 0, 1, 0, 0, 1, 1, 1,
			0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 1, 0, 0, 1, 1, 1,
		};
		// black semi-transparent pixel
		constexpr uint32_t shadow_fill_color = std::endian::native == std::endian::little ? 0x80000000 : 0x00000080;
		constexpr uint32_t shadow_no_color = 0x00000000;

		std::vector<uint32_t> shadow_texture_data(128 * 128);
		for (size_t i = 0; i < 128 * 128; ++i) {
			shadow_texture_data[i] = opaque_quaters[i / 128 / 16][i % 128 / 16] ? shadow_fill_color : shadow_no_color;
		}

		constexpr staplegl::resolution shadow_resolution = {
			.width = 128,
			.height = 128
		};
		constexpr staplegl::texture_color shadow_format = {
			.internal_format = GL_RGBA,
			.format = GL_RGBA,
			.datatype = GL_UNSIGNED_BYTE
		};
		constexpr staplegl::texture_filter shadow_filter = {
			.min_filter = GL_LINEAR,
			.mag_filter = GL_LINEAR,
			.clamping = GL_CLAMP_TO_BORDER
		};

		std::span<const uint32_t> shadow_span(shadow_texture_data.begin(), shadow_texture_data.end());
		return staplegl::texture_2d(shadow_span, shadow_resolution, shadow_format, shadow_filter);
	}

	TilemapRenderContext::TilemapRenderContext(RxTilemap* tilemap) :
		render_width(0),
		render_height(0),
		instances_count(0)
	{
		// init shadow texture if it doesn't
		if (shadow_texture.id() == 0) {
			shadow_texture = make_shadow_texture();
		}
	}

	void TilemapRenderContext::emplace_data_from(RxTilemap* tilemap) {
		if (!tilemap->map_data) {
			//mod_loader->log_info("Tilemap data is null\n");
			return;
		}

		TilePrimitivesReader tilemap_reader(tilemap, 0);

		instances_count = tilemap_reader.instance_count();
		if (instances_count == 0) {
			mod_loader->log_info("Tilemap has 0 primitives\n");
			return;
		}

		auto data_span = tilemap_reader.data_span();
		mod_loader->log_info("Tilemap primitives {}, span size {}\n", instances_count, data_span.size());
		vao.instanced_data()->set_data(data_span, staplegl::driver_draw_hint::DYNAMIC_DRAW);
	}

	void TilemapRenderContext::emplace_texture(RxTilemap* tilemap, int index) {
		if (index >= max_textures || !tilemap->tilesets_surfaces[index]) {
			//mod_loader->log_info("Tilemap render warning: tried to access empty texture or passed invalid index\n");
			return;
		}

		Surface* surface = tilemap->tilesets_surfaces[index];
		staplegl::resolution surface_res = {
			.width = surface->info.bitmap->bmiHeader.biWidth,
			.height = surface->info.bitmap->bmiHeader.biHeight,
		};

		if (surface_res.width <= 1 && surface_res.height <= 1) {
			//mod_loader->log_info("Tried to emplace empty texture?\n");
			return;
		}

		staplegl::texture_color surface_color = {
			.internal_format = GL_RGBA,
			.format = GL_BGRA,
			.datatype = GL_UNSIGNED_BYTE
		};

		staplegl::texture_filter surface_filter = {
			.min_filter = GL_LINEAR,
			.mag_filter = GL_LINEAR,
			.clamping = GL_CLAMP_TO_BORDER
		};

		//mod_loader->log_info("Emplaced texture ({} bits)\n", surface->info.bitmap->bmiHeader.biBitCount);

		std::span<const BYTE> surface_bits(surface->image.bits, surface_res.width * surface_res.height * 4);
		textures[index] = staplegl::texture_2d(surface_bits, surface_res, surface_color, surface_filter);
	}

	void TilemapRenderContext::emplace_all_textures(RxTilemap* tilemap) {
		for (int i = 0; i < textures.size(); ++i) {
			emplace_texture(tilemap, i);
		}
	}

	void TilemapRenderContext::bind_all_textures_to(staplegl::shader_program& shader) {
		// bind tilesets textures
		for (size_t i : iota(0ULL, textures.size())) {
			textures[i].set_unit(i);
			shader.upload_uniform2f(
				std::format("uTexturesInfos[{}].texture_size", i),
				textures[i].get_resolution().width,
				textures[i].get_resolution().height
			);
			shader.upload_uniform1i(
				std::format("uTexturesInfos[{}].texture", i),
				i
			);
		}

		shadow_texture.set_unit(9);
		// bind shadow texture
		shader.upload_uniform2f(
			"uTexturesInfos[9].texture_size",
			shadow_texture.get_resolution().width,
			shadow_texture.get_resolution().height
		);
		shader.upload_uniform1i(
			"uTexturesInfos[9].texture",
			9
		);
	}
	
	// TODO: add error handling
	GLRenderer::GLRenderer(GLFWwindow* window, int width, int height) :
		window_width_(width),
		window_height_(height),
		window_(window),
		initial_time_(std::chrono::high_resolution_clock::now())
	{
		const std::filesystem::path data_path = mod_loader->get_data_dir();
		const std::filesystem::path shaders_path = data_path / shaders_subpath;

		mod_loader->log_info("Shaders path: {}\n", shaders_path.string());

		sprites_shader_ = staplegl::shader_program("sprites", {
			{ staplegl::shader_type::vertex, shaders_path / "sprite.glsv" },
			{ staplegl::shader_type::fragment, shaders_path / "sprite.glsf" },
		});

		if (!staplegl::shader_program::is_valid(sprites_shader_.program_id())) {
			mod_loader->log_info("Failed to compile sprites shader\n");
			check_shader_program(sprites_shader_);
			return; // throw error
		}

		tilemap_shader_ = staplegl::shader_program("tilemap", {
			{ staplegl::shader_type::vertex, shaders_path / "tilemap.glsv" },
			{ staplegl::shader_type::fragment, shaders_path / "tilemap.glsf" },
		});

		if (!staplegl::shader_program::is_valid(tilemap_shader_.program_id())) {
			mod_loader->log_info("Failed to compile tilemap shader\n");
			check_shader_program(tilemap_shader_);
			return; // throw error
		}

		staplegl::vertex_buffer sprites_vbo(rect_vertices_, staplegl::driver_draw_hint::STATIC_DRAW);
		staplegl::index_buffer sprites_ebo(rect_indices_);
		staplegl::vertex_buffer_inst sprites_ibo({}, 0);

		sprites_vbo.set_layout(make_vbo_layout());
		sprites_ibo.set_layout(make_sprites_layout());

		sprites_vao_.add_vertex_buffer(std::move(sprites_vbo));
		sprites_vao_.set_index_buffer(std::move(sprites_ebo));
		sprites_vao_.set_instance_buffer(std::move(sprites_ibo));

		glEnable(GL_DEPTH_TEST);
		glEnable(GL_BLEND);
		//glBlendEquation(GL_FUNC_ADD);
		//glBlendEquation(GL_FUNC_SUBTRACT);
		glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		glEnable(GL_CLIP_DISTANCE0);
		glEnable(GL_CLIP_DISTANCE1);

		//glEnablei(GL_BLEND, 1);
		//glBlendFunci(1, GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		//GLenum draw_buffer_indices[] = { GL_FRONT_LEFT, GL_FRONT_RIGHT };
		//glDrawBuffers(2, draw_buffer_indices);
	}

	GLRenderer::~GLRenderer() {
		glfwDestroyWindow(window_);
		glfwTerminate();
	}

	void GLRenderer::add_tilemap_context(RxTilemap* tilemap) {
		TilemapRenderContext& context = tilemap_contexts_.emplace(std::make_pair(tilemap, TilemapRenderContext(tilemap))).first->second;

		staplegl::vertex_buffer vbo(rect_vertices_, staplegl::driver_draw_hint::STATIC_DRAW);
		staplegl::index_buffer ebo(rect_indices_);
		staplegl::vertex_buffer_inst ibo({}, 0);

		vbo.set_layout(make_vbo_layout());
		ibo.set_layout(make_tilemap_layout());

		context.vao.add_vertex_buffer(std::move(vbo));
		context.vao.set_index_buffer(std::move(ebo));
		context.vao.set_instance_buffer(std::move(ibo));

		context.emplace_all_textures(tilemap);
		context.emplace_data_from(tilemap);
	}

	void GLRenderer::on_tilemap_changed_data(RxTilemap* tilemap) {
		if (!tilemap_contexts_.contains(tilemap)) {
			add_tilemap_context(tilemap);
			return;
		}
		TilemapRenderContext& context = tilemap_contexts_.at(tilemap);
		context.emplace_data_from(tilemap);
	}

	void GLRenderer::on_tilemap_changed_tileset(RxTilemap* tilemap, int index) {
		if (!tilemap_contexts_.contains(tilemap)) {
			add_tilemap_context(tilemap);
			return;
		}
		TilemapRenderContext& context = tilemap_contexts_.at(tilemap);
		context.emplace_texture(tilemap, index);
	}

	void GLRenderer::on_tilemap_destroyed(RxTilemap* tilemap) {
		tilemap_contexts_.erase(tilemap);
	}

	std::optional<SpriteRenderPrimitive> GLRenderer::make_sprite_primitive(RxSprite* sprite) {
		//if (!sprite->surface90) {
		//	mod_loader->log_info("Sprite with null surface\n");
		//	return std::nullopt;
		//}
		//Surface* sprite_surface = sprite->surface90;

		//if (!sprite_surface->image.bits) {
		//	mod_loader->log_info("Sprite with null image bits\n");
		//	return std::nullopt;
		//}
		//if (!sprite_surface->info.bitmap) {
		//	mod_loader->log_info("Sprite with null bitmap\n");
		//	return std::nullopt;
		//}

		//staplegl::resolution surface_res = {
		//	.width = sprite_surface->info.bitmap->bmiHeader.biWidth,
		//	.height = sprite_surface->info.bitmap->bmiHeader.biHeight
		//};
		//staplegl::texture_color surface_color = {
		//	.internal_format = GL_RGBA,
		//	.format = GL_BGRA,
		//	.datatype = GL_UNSIGNED_BYTE
		//};

		//staplegl::texture_filter surface_filter = {
		//	.min_filter = GL_LINEAR,
		//	.mag_filter = GL_LINEAR,
		//	.clamping = GL_CLAMP_TO_BORDER
		//};

		//std::span<const float> texture_span(reinterpret_cast<const float*>(sprite_surface->image.bits), surface_res.width * surface_res.height * 4);
		//GLuint64 texture_handle = 0;
		//if (drawn_sprites_.find(sprite) == drawn_sprites_.end()) {
		//	staplegl::texture_2d& texture = sprite_textures_.emplace_back(texture_span, surface_res, surface_color, surface_filter);
		//	texture_handle = glGetTextureHandleARB(texture.id());
		//	glMakeTextureHandleResidentARB(texture_handle);
		//}
		//else {
		//	staplegl::texture_2d& texture = sprite_textures_[drawn_sprites_[sprite]];
		//	texture.set_data(texture_span, surface_res, surface_color);

		//	texture_handle = glGetTextureHandleARB(texture.id());
		//	glMakeTextureHandleResidentARB(texture_handle);
		//}

		//int width = sprite->src_rect.right - sprite->src_rect.left;
		//int height = sprite->src_rect.bottom - sprite->src_rect.top;
		//int x = sprite->src_rect.left + sprite->origin.x;
		//int y = sprite->src_rect.top;

		//return SpriteRenderPrimitive(
		//	glm::vec3(sprite->offset_x, sprite->offset_y, sprite->gap34[3] / 40.f),
		//	glm::vec2(width / 32.f * sprite->zoom_x, height / 32.f * sprite->zoom_y),
		//	glm::vec2((x - width / 2.) / static_cast<float>(surface_res.width), y / static_cast<float>(surface_res.height)),
		//	glm::vec2(width / static_cast<float>(surface_res.width), height / static_cast<float>(surface_res.height)),
		//	texture_handle
		//);

		return std::nullopt;
	}

	void GLRenderer::on_sprite_constructed(RxSprite* sprite) {
		if (sprite_context_indices_.find(sprite) != sprite_context_indices_.end()) {
			return;
		}

		SpriteRenderContext& context = sprite_contexts_.emplace_back();

		staplegl::resolution surface_res = {
			.width = 0,
			.height = 0
		};
		staplegl::texture_color surface_color = {
			.internal_format = GL_RGBA,
			.format = GL_BGRA,
			.datatype = GL_UNSIGNED_BYTE
		};

		staplegl::texture_filter surface_filter = {
			.min_filter = GL_LINEAR,
			.mag_filter = GL_LINEAR,
			.clamping = GL_CLAMP_TO_BORDER
		};

		std::span<const float> texture_span;

		if (sprite->surface90 && sprite->surface90->image.bits && sprite->surface90->info.bitmap) {
			Surface* sprite_surface = sprite->surface90;

			surface_res = {
				.width = sprite_surface->info.bitmap->bmiHeader.biWidth,
				.height = sprite_surface->info.bitmap->bmiHeader.biHeight
			};

			texture_span = std::span<const float>(reinterpret_cast<const float*>(sprite_surface->image.bits), surface_res.width * surface_res.height * 4);
		}

		staplegl::texture_2d& texture = surface_textures_[sprite->surface90];
		texture = staplegl::texture_2d(texture_span, surface_res, surface_color, surface_filter);
		GLuint64 texture_handle = glGetTextureHandleARB(texture.id());
		glMakeTextureHandleResidentARB(texture_handle);

		int width = sprite->src_rect.right - sprite->src_rect.left;
		int height = sprite->src_rect.bottom - sprite->src_rect.top;
		int x = sprite->src_rect.left + sprite->origin.x;
		int y = sprite->src_rect.top;

		context.sprite = sprite;
		context.primitive.offset = glm::vec3(sprite->offset_x, sprite->offset_y, sprite->offset_z / 40.f);
		context.primitive.zoom = glm::vec2(width / 32.f * sprite->zoom_x, height / 32.f * sprite->zoom_y);
		context.primitive.texture_offset = glm::vec2(std::max(x - width / 2., 0.) / static_cast<float>(surface_res.width), y / static_cast<float>(surface_res.height));
		context.primitive.texture_size = glm::vec2(width / static_cast<float>(surface_res.width), height / static_cast<float>(surface_res.height));
		context.primitive.texture_handle = texture_handle;
		context.primitive.opacity = sprite->opacity / 255.f;

		sprites_vao_.instanced_data()->add_instance(sprite_value_ptr(context.primitive));
		sprite_context_indices_[sprite] = context.vao_index = sprites_vao_.instanced_data()->instance_count() - 1;
	}

	void GLRenderer::on_sprite_updated(RxSprite* sprite) {
		if (sprite_context_indices_.find(sprite) == sprite_context_indices_.end()) {
			mod_loader->log_info("Sprite 0x{:X} not found\n", reinterpret_cast<uintptr_t>(sprite));
			return;
		}

		int sprite_width = sprite->rect.right - sprite->rect.left;
		int sprite_height = sprite->rect.bottom - sprite->rect.top;
		int sprite_x = sprite->offset_x;
		int sprite_y = sprite->offset_y;
		float sprite_z = sprite->offset_z / 512.f;

		Sprite* iter_ancestor = sprite->ancestor;
		bool is_visible = false;
		int ancestor_depth = 0;
		while (iter_ancestor) {
			iter_ancestor = iter_ancestor->ancestor;
			ancestor_depth++;
		}

		iter_ancestor = sprite->ancestor;
		while (iter_ancestor && !is_visible) {
			sprite_x += iter_ancestor->offset_x;
			sprite_y += iter_ancestor->offset_y;
			sprite_z += (iter_ancestor->offset_z * std::pow(4,  ancestor_depth) / 32.f) + 0.01f;
			//sprite_z += 0.1f;
			is_visible = iter_ancestor == mod_loader->get_game()->screen;

			iter_ancestor = iter_ancestor->ancestor;
			ancestor_depth--;
		}
		is_visible = is_visible && sprite->is_visible;
		sprite_z = std::clamp(sprite_z, 0.f, (max_z_layer - 1) * 4.f);
		sprite_z += static_cast<float>(sprite_y) / window_height_;

		sprite_z /= 4.f;

		int width = sprite->src_rect.right - sprite->src_rect.left;
		int height = sprite->src_rect.bottom - sprite->src_rect.top;
		int x = sprite->src_rect.left + sprite->origin.x;
		int y = sprite->src_rect.top;

		//is_visible = is_visible && (sprite->blend_type & 7) != 1;

		glm::vec3 pos(sprite_x, sprite_y, std::clamp(sprite_z, 0.f, static_cast<float>(max_z_layer)));

		SpriteRenderContext& context = sprite_contexts_[sprite_context_indices_.at(sprite)];

		GLuint64 texture_handle = 0;
		staplegl::resolution surface_res;
		if (sprite->surface90 && surface_textures_.find(sprite->surface90) != surface_textures_.end()) {
			staplegl::texture_2d& texture = surface_textures_.at(sprite->surface90);
			surface_res = texture.get_resolution();
			texture_handle = glGetTextureHandleARB(texture.id());
		}
		else if (is_visible && sprite->surface90) {
			//mod_loader->log_info("Surface 0x{:X} not found\n", reinterpret_cast<uintptr_t>(sprite->surface90));
			//on_sprite_updated_texture(sprite);

			Surface* sprite_surface = sprite->surface90;

			surface_res = {
				.width = sprite_surface->info.bitmap->bmiHeader.biWidth,
				.height = sprite_surface->info.bitmap->bmiHeader.biHeight
			};
			staplegl::texture_color surface_color = {
				.internal_format = GL_RGBA,
				.format = GL_BGRA,
				.datatype = GL_UNSIGNED_BYTE
			};

			staplegl::texture_filter surface_filter = {
				.min_filter = GL_LINEAR,
				.mag_filter = GL_LINEAR,
				.clamping = GL_CLAMP_TO_BORDER
			};
			std::span<const float> texture_span(reinterpret_cast<const float*>(sprite_surface->image.bits), surface_res.width * surface_res.height * 4);

			staplegl::texture_2d& texture = surface_textures_[sprite_surface];
			texture = staplegl::texture_2d(texture_span, surface_res, surface_color, surface_filter);
			texture_handle = glGetTextureHandleARB(texture.id());
			glMakeTextureHandleResidentARB(texture_handle);
		}

		context.primitive.offset = glm::vec3(sprite_x, sprite_y, std::clamp(sprite_z, 0.f, static_cast<float>(max_z_layer)));
		context.primitive.zoom = glm::vec2(sprite_width / 32.f * sprite->zoom_x, sprite_height / 32.f * sprite->zoom_y);
		context.primitive.texture_offset = glm::vec2(std::clamp((x - width / 2.f) / static_cast<float>(surface_res.width), 0.f, 1.f), std::clamp(y / static_cast<float>(surface_res.height), 0.f, 1.f));
		context.primitive.texture_size = glm::vec2(width / static_cast<float>(surface_res.width), height / static_cast<float>(surface_res.height));
		//context.primitive.zoom = glm::vec2(sprite_width / 32.f, sprite_height / 32.f);
		//context.primitive.texture_offset = glm::vec2(0.f);
		//context.primitive.texture_size = glm::vec2(1.f);
		context.primitive.texture_handle = texture_handle;
		context.primitive.opacity = sprite->opacity / 255.f * (is_visible ? 1.f : 0.f);

		sprites_vao_.instanced_data()->update_instance(context.vao_index, sprite_value_ptr(context.primitive));

		while (context.vao_index > 0 && context.primitive.offset.z < sprite_contexts_[context.vao_index - 1].primitive.offset.z) {
			// move left, to lower higher priority, because z level is lower than previous primitive
			// This is needed to properly blend transparency. Lower offset_z => father from camera => higher render priority
			auto& prev_context = sprite_contexts_[context.vao_index - 1];
			sprite_context_indices_.at(prev_context.sprite) = ++prev_context.vao_index;
			sprite_context_indices_.at(sprite) = --context.vao_index;
			std::swap(context, prev_context);
		
			sprites_vao_.instanced_data()->update_instance(prev_context.vao_index, sprite_value_ptr(prev_context.primitive));
			sprites_vao_.instanced_data()->update_instance(context.vao_index, sprite_value_ptr(context.primitive));
		}
		
		//while (context.vao_index < sprite_contexts_.size() - 1 && context.primitive.offset.z > sprite_contexts_[context.vao_index + 1].primitive.offset.z) {
		//	// move right, to lower render priority, because z level is higher than previous primitive
		//	// This is needed to properly blend transparency. Higher offset_z => closer to camera => lower render priority
		//	auto& next_context = sprite_contexts_[context.vao_index + 1];
		//	sprite_context_indices_.at(next_context.sprite) = --next_context.vao_index;
		//	sprite_context_indices_.at(sprite) = ++context.vao_index;
		//	std::swap(context, next_context);
		//
		//	sprites_vao_.instanced_data()->update_instance(next_context.vao_index, sprite_value_ptr(next_context.primitive));
		//	sprites_vao_.instanced_data()->update_instance(context.vao_index, sprite_value_ptr(context.primitive));
		//}
	}

	void GLRenderer::on_sprite_updated_texture(RxSprite* sprite) {
		if (!sprite->surface90) {
			mod_loader->log_info("Sprite with null surface\n");
			return;
		}

		Surface* sprite_surface = sprite->surface90;

		if (surface_textures_.find(sprite_surface) != surface_textures_.end()) {
			on_surface_changed(sprite_surface);
		}
		else {
			//mod_loader->log_info("Sprite updated texture, but not found in textures map\n");
			staplegl::resolution surface_res = {
				.width = sprite_surface->info.bitmap->bmiHeader.biWidth,
				.height = sprite_surface->info.bitmap->bmiHeader.biHeight
			};
			staplegl::texture_color surface_color = {
				.internal_format = GL_RGBA,
				.format = GL_BGRA,
				.datatype = GL_UNSIGNED_BYTE
			};

			staplegl::texture_filter surface_filter = {
				.min_filter = GL_LINEAR,
				.mag_filter = GL_LINEAR,
				.clamping = GL_CLAMP_TO_BORDER
			};
			std::span<const float> texture_span(reinterpret_cast<const float*>(sprite_surface->image.bits), surface_res.width * surface_res.height * 4);

			staplegl::texture_2d& texture = surface_textures_[sprite_surface];
			texture = staplegl::texture_2d(texture_span, surface_res, surface_color, surface_filter);
			GLuint64 texture_handle = glGetTextureHandleARB(texture.id());
			glMakeTextureHandleResidentARB(texture_handle);
		}

		on_sprite_updated(sprite);
	}

	void GLRenderer::on_sprite_destructed(RxSprite* sprite) {
		int context_index = sprite_context_indices_.at(sprite);

		SpriteRenderContext& destructed_sprite_context = sprite_contexts_[context_index];
		
		sprites_vao_.instanced_data()->delete_instance(destructed_sprite_context.vao_index);
		sprite_contexts_.erase(std::next(sprite_contexts_.begin(), context_index));
		sprite_context_indices_.erase(sprite);

		while (context_index < sprite_contexts_.size()) {
			// subtract all next sprite indices by 1
			SpriteRenderContext& sprite_context = sprite_contexts_[context_index];
			sprite_context_indices_.at(sprite_context.sprite) = sprite_context.vao_index = context_index++;
			sprites_vao_.instanced_data()->update_instance(sprite_context.vao_index, sprite_value_ptr(sprite_context.primitive));
		}
	}

	void GLRenderer::on_surface_changed(Surface* surface) {
		if (surface_textures_.find(surface) == surface_textures_.end()) {
			//mod_loader->log_info("Surface 0x{:X} not found\n", reinterpret_cast<uintptr_t>(surface));
			return;
		}

		if (!surface->image.bits) {
			mod_loader->log_info("Surface with null image bits\n");
			return;
		}
		if (!surface->info.bitmap) {
			mod_loader->log_info("Surface with null bitmap\n");
			return;
		}

		staplegl::resolution surface_res = {
			.width = surface->info.bitmap->bmiHeader.biWidth,
			.height = surface->info.bitmap->bmiHeader.biHeight
		};
		staplegl::texture_color surface_color = {
			.internal_format = GL_RGBA,
			.format = GL_BGRA,
			.datatype = GL_UNSIGNED_BYTE
		};
		staplegl::texture_filter surface_filter = {
			.min_filter = GL_LINEAR,
			.mag_filter = GL_LINEAR,
			.clamping = GL_CLAMP_TO_BORDER
		};

		if (surface_res.width == 0 || surface_res.height == 0) {
			return;
		}

		std::span<const float> texture_span(reinterpret_cast<const float*>(surface->image.bits), surface_res.width * surface_res.height);

		staplegl::texture_2d& texture = surface_textures_.at(surface);
		if (texture.get_resolution().width == surface_res.width && texture.get_resolution().height == surface_res.height) {
			texture.bind();
			texture.set_data(texture_span, surface_res, surface_color);
		}
		else {
			// There is a bug in texture_2d move operarator, it isn't deleting the texture object,
			// so call destructor directly
			texture.~texture_2d();
			texture = staplegl::texture_2d(texture_span, surface_res, surface_color, surface_filter);
			GLuint64 texture_handle = glGetTextureHandleARB(texture.id());
			glMakeTextureHandleResidentARB(texture_handle);
		}
	}

	void GLRenderer::on_surface_destructed(Surface* surface) {
		if (surface_textures_.find(surface) != surface_textures_.end()) {
			surface_textures_.erase(surface);
		}
	}

	void GLRenderer::render_screen(Screen* screen) {
		//glPolygonMode(GL_FRONT_AND_BACK, GL_LINE);
		//glLineWidth(2);

		//glClearColor(0.2F, 0.3F, 0.3F, 1.0F);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

		render_sprites(screen);
		render_tilemap(screen);
		poll();
	}

	void GLRenderer::render_sprites(Screen* screen) {
		glm::mat4 view_mat = glm::ortho(0., double(window_width_), double(window_height_), 0., -double(max_z_layer), 0.5);
		
		sprites_shader_.bind();
		sprites_shader_.upload_uniform_mat4f("uView", glm::value_ptr(view_mat));
		sprites_shader_.upload_uniform3f("uGlobalOffset", 0.f, 0.f, 0.f);

		for (auto& context : sprite_contexts_) {
			on_sprite_updated(context.sprite);
			//on_sprite_updated_texture(context.sprite);
		}
		
		sprites_vao_.bind();
		glDrawElementsInstanced(GL_TRIANGLES, rect_indices_.size(), GL_UNSIGNED_INT, nullptr, sprites_vao_.instanced_data()->instance_count());

		//mod_loader->log_info("Sprites instances {}, textures count {}       \r", sprites_vao_.instanced_data()->instance_count(), surface_textures_.size());
	}

	void GLRenderer::render_tilemap(Screen* screen) {
		// Only render tilemap
		// TODO: render all other things
		using namespace std::chrono;

		// Used to transform screen coordinates to device local coordinates
		glm::mat4 view_mat = glm::ortho(0., double(window_width_), double(window_height_), 0., -double(max_z_layer), 0.5);
		//glm::mat4 projection_mat = glm::perspective(0, )

		tilemap_shader_.bind();
		tilemap_shader_.upload_uniform_mat4f("uView", glm::value_ptr(view_mat));
		tilemap_shader_.upload_uniform2f("uScreenSize", window_width_, window_height_);
		tilemap_shader_.upload_uniform2f("uViewportSize", window_width_, window_height_);
		tilemap_shader_.upload_uniform1i("uAnimationClock", duration_cast<milliseconds>(high_resolution_clock::now() - initial_time_) / animation_delta);
		
		for (auto& [tilemap, tilemap_context] : tilemap_contexts_) {
			tilemap_context.vao.bind();
			tilemap_context.bind_all_textures_to(tilemap_shader_);

			DWORD color = static_cast<RxViewport*>(tilemap->tilemap_sprite8->ancestor)->color;
			tilemap_shader_.upload_uniform4f("uColor", (color & 0xFF) / 255., ((color >> 8) & 0xFF) / 255., ((color >> 16) & 0xFF) / 255., ((color >> 24) & 0xFF) / 255.);
			tilemap_shader_.upload_uniform3f("uGlobalOffset", -static_cast<float>(tilemap->offset_x), -static_cast<float>(tilemap->offset_y), 0.);

			//mod_loader->log_info("Rendering tilemap {} instances, texture[0] size: {{{}, {}}}     \r", tilemap_context.instances_count, tilemap_context.textures[0].get_resolution().width, tilemap_context.textures[0].get_resolution().height);
			//mod_loader->log_info("Rendering tilemap[0] {} instances, total {} tilemaps        \r", tilemap_context.instances_count, tilemap_contexts_.size());

			glDrawElementsInstanced(GL_TRIANGLES, rect_indices_.size(), GL_UNSIGNED_INT, nullptr, tilemap_context.instances_count);
		}
	}

	void GLRenderer::poll() const {
		// Original update_screen already has vsync support, so glfw doesn't need to care about it.
		// Actually, game vsync can be turned off if DirectDraw pointers were nullified.
		//glfwSwapInterval(0);
		glfwSwapBuffers(window_);
		glfwPollEvents();
	}

	GLFWwindow* GLRenderer::make_window(int width, int height) {
		// glfw has already inited by the ModLoader

		glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 4);
		glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 3);

		GLFWwindow* window = glfwCreateWindow(width, height, "Test", nullptr, nullptr);
		if (!window) {
			mod_loader->log_info("Failed to create window\n");
			glfwTerminate();
			return nullptr; // throw error
		}

		glfwMakeContextCurrent(window);
		glfwSetKeyCallback(window, glfw_key_callback);

		if (!glad_inited_ && !gladLoadGLLoader(reinterpret_cast<GLADloadproc>(glfwGetProcAddress))) {
			mod_loader->log_info("Failed to init glad\n");
			glfwTerminate();
			return nullptr; // throw error
		}
		glad_inited_ = true;

		return window;
	}

	void print_childs(Sprite* sprite, int indent) {
		if (!sprite->child_begin || !sprite->child_end || sprite->child_begin >= sprite->child_end) {
			return;
		}

		std::string indent_str;
		for (auto i = 0; i < indent; ++i) {
			indent_str += ' ';
		}
		for (auto iter = sprite->child_begin; iter < sprite->child_end; ++iter) {
			Sprite* sprite = *iter;

			RTTIObjectLocator* obj_locator = get_object_locator(sprite);
			if (obj_locator->type_info->name() == RxSprite::type_name || obj_locator->type_info->name() == SurfaceSprite::type_name) {
				SurfaceSprite* surface_sprite = static_cast<SurfaceSprite*>(sprite);
				mod_loader->log_info(
					"{}{} {{{}, {}, {}, {}}}, z={} (0x{:X}), surface 0x{:X}\n",
					indent_str,
					obj_locator->type_info->name(),
					sprite->offset_x,
					sprite->offset_y,
					sprite->rect.right - sprite->rect.left,
					sprite->rect.bottom - sprite->rect.top,
					sprite->offset_z,
					reinterpret_cast<uintptr_t>(sprite),
					reinterpret_cast<uintptr_t>(surface_sprite->surface90)
				);
			}
			else {
				mod_loader->log_info(
					"{}{} {{{}, {}, {}, {}}}, z={} (0x{:X})\n",
					indent_str,
					obj_locator->type_info->name(),
					sprite->offset_x,
					sprite->offset_y,
					sprite->rect.right - sprite->rect.left,
					sprite->rect.bottom - sprite->rect.top,
					sprite->offset_z,
					reinterpret_cast<uintptr_t>(sprite)
				);
			}
			print_childs(sprite, indent + 1);
		}
	}

	void dump_surface(Surface* surface, const std::filesystem::path& path) {
#pragma pack(push, 1)
		struct BmpHeader {
			char bitmapSignatureBytes[2] = { 'B', 'M' };
			uint32_t sizeOfBitmapFile = 54 + 0;
			uint32_t reservedBytes = 0;
			uint32_t pixelDataOffset = 54;
		} bmp_header;

		struct BmpInfoHeader {
			uint32_t sizeOfThisHeader = 40;
			int32_t width = 0; // in pixels
			int32_t height = 0; // in pixels
			uint16_t numberOfColorPlanes = 1; // must be 1
			uint16_t colorDepth = 32;
			uint32_t compressionMethod = 0;
			uint32_t rawBitmapDataSize = 0; // generally ignored
			int32_t horizontalResolution = 0; // in pixel per meter
			int32_t verticalResolution = 0; // in pixel per meter
			uint32_t colorTableEntries = 0;
			uint32_t importantColors = 0;
		} bmp_info_header;
#pragma pack(pop)

		bmp_info_header.width = surface->info.bitmap->bmiHeader.biWidth;
		bmp_info_header.height = surface->info.bitmap->bmiHeader.biHeight;

		if (bmp_info_header.width == 0 || bmp_info_header.height == 0) {
			return;
		}

		std::span<uint8_t> surface_span(surface->image.bits, bmp_info_header.width * bmp_info_header.height * 4);

		bmp_header.sizeOfBitmapFile = 54 + surface_span.size_bytes();

		std::ofstream file_stream(path, std::ios::binary);

		file_stream.write(reinterpret_cast<char*>(&bmp_header), sizeof(BmpHeader));
		file_stream.write(reinterpret_cast<char*>(&bmp_info_header), sizeof(BmpInfoHeader));

		file_stream.write(reinterpret_cast<char*>(surface_span.data()), surface_span.size_bytes());
	}

	void GLRenderer::glfw_key_callback(GLFWwindow* window, int key, int scancode, int action, int mods) {
		if (key == GLFW_KEY_K && action == GLFW_PRESS) {
			mod_loader->log_info("\n");
			for (auto& context : shared_renderer->sprite_contexts_) {
				mod_loader->log_info(
					"  {}: (0x{:X}), opacity={}, z={}\n",
					context.vao_index,
					reinterpret_cast<uintptr_t>(context.sprite),
					context.primitive.opacity,
					context.primitive.offset.z
				);
			}
		}
		if (key == GLFW_KEY_J && action == GLFW_PRESS) {
			mod_loader->log_info("\n");
			print_childs(mod_loader->get_game()->screen, 0);
		}
		if (key == GLFW_KEY_H && action == GLFW_PRESS) {
			Screen* screen = mod_loader->get_game()->screen;
			for (auto iter = screen->child_begin; iter < screen->child_end; ++iter) {
				RTTIObjectLocator* obj_locator = get_object_locator(*iter);
				if (obj_locator->type_info->name() != RxSprite::type_name) {
					continue;
				}

				RxSprite* sprite = static_cast<RxSprite*>(*iter);
				if (shared_renderer->sprite_context_indices_.find(sprite) == shared_renderer->sprite_context_indices_.end()) {
					shared_renderer->on_sprite_constructed(sprite);
				}
			}
		}
		if (key == GLFW_KEY_G && action == GLFW_PRESS) {
			for (auto& context : shared_renderer->sprite_contexts_) {
				mod_loader->log_info("Sprite (0x{:X}) z={}\n", reinterpret_cast<uintptr_t>(context.sprite), context.primitive.offset.z);
			}
		}
		if (key == GLFW_KEY_T && action == GLFW_PRESS) {
			for (auto& [surface, texture] : shared_renderer->surface_textures_) {
				if (surface && surface->image.bits && surface->info.bitmap) {
					dump_surface(surface, std::format("mod_loader/dump/{:X}.bmp", reinterpret_cast<uintptr_t>(surface)));
				}
			}
		}
		//if (key == GLFW_KEY_Y && action == GLFW_PRESS) {
		//	for (auto& [surface, texture] : shared_renderer->surface_textures_) {
		//		texture.
		//	}
		//}
	}

	int __thiscall RxTilemapFRHook::update_data_hook(WORD* map_data, DWORD width, DWORD height, DWORD depth) {
		int ret = (this->*orig_update_data)(map_data, width, height, depth);

		mod_loader->log_info("Tilemap has changed data\n");
		shared_renderer->on_tilemap_changed_data(this);
		return ret;
	}

	int __thiscall RxTilemapFRHook::set_surface_at_hook(unsigned int index, Surface* surface) {
		int ret = (this->*orig_set_surface_at)(index, surface);

		mod_loader->log_info("Tilemap has changed surface at {}\n", index);
		shared_renderer->on_tilemap_changed_tileset(this, index);
		return ret;
	}

	RxTilemap* __thiscall RxTilemapFRHook::tilemap_destructor_hook(char a1) {
		mod_loader->log_info("Tilemap was destroyed\n");
		shared_renderer->on_tilemap_destroyed(this);
		return (this->*orig_tilemap_destructor)(a1);
	}

	int(__thiscall RxTilemap::* RxTilemapFRHook::orig_update_data)(WORD* map_data, DWORD width, DWORD height, DWORD depth) = nullptr;
	int(__thiscall RxTilemap::* RxTilemapFRHook::orig_set_surface_at)(unsigned int index, Surface* a3) = nullptr;
	RxTilemap* (__thiscall RxTilemap::* RxTilemapFRHook::orig_tilemap_destructor)(char a1) = nullptr;

	int __thiscall ScreenFastRenderHook::update_screen_hook(int a1, int a2) {
		shared_renderer->render_screen(this);
		return (this->*orig_update_screen)(a1, a2);
		//return 1;
	}
	int(__thiscall Screen::* ScreenFastRenderHook::orig_update_screen)(int a1, int a2) = nullptr;

	RxSprite* __thiscall RxSpriteFRHook::constructor_hook(Sprite* ancestor) {
		(this->*orig_constructor)(ancestor);
		shared_renderer->on_sprite_constructed(this);
		return this;
	}

	RxSprite* __thiscall RxSpriteFRHook::destructor_hook(char a1) {
		(this->*orig_destructor)(a1);
		shared_renderer->on_sprite_destructed(this);
		return this;
	}

	Surface* __thiscall RxSpriteFRHook::set_surface_hook(Surface* surface, RECT* src_rect) {
		bool surface_changed = surface != surface90;
		Surface* ret = (this->*orig_set_surface)(surface, src_rect);
		if (surface != nullptr) {
			//mod_loader->log_info("set_surface: Surface (0x{:X}), this (0x{:X})\n", reinterpret_cast<uintptr_t>(surface), reinterpret_cast<uintptr_t>(surface90));
			shared_renderer->on_sprite_updated_texture(this);
		}
		return ret;
	}

	int __thiscall RxSpriteFRHook::update_data_hook() {
		int ret = (this->*orig_update_data)();
		shared_renderer->on_sprite_updated(this);
		return ret;
	}

	int __thiscall RxSpriteFRHook::flash_hook(DWORD color, int duration) {
		mod_loader->log_info("RxSprite flash: color = #{:X}, duration = {}\n", color, duration);
		return (this->*orig_flash)(color, duration);
	}

	RxSprite* (__thiscall RxSprite::* RxSpriteFRHook::orig_constructor)(Sprite* ancestor) = nullptr;
	RxSprite* (__thiscall RxSprite::* RxSpriteFRHook::orig_destructor)(char a1) = nullptr;
	Surface* (__thiscall RxSprite::* RxSpriteFRHook::orig_set_surface)(Surface* surface, RECT* src_rect) = nullptr;
	int(__thiscall RxSprite::* RxSpriteFRHook::orig_update_data)() = nullptr;

	int(__thiscall RxSprite::* RxSpriteFRHook::orig_flash)(DWORD color, int duration) = nullptr;

	struct SurfaceFRHook : Surface {
		static int(__thiscall Surface::* orig_draw_on_surface)(RECT* dest_rect, Surface* src_surface, RECT* src_rect, int* a5);
		static Surface*(__thiscall Surface::* orig_destructor)(char a1);

		int __thiscall draw_on_surface_hook(RECT* dest_rect, Surface* src_surface, RECT* src_rect, int* a5);
		Surface* __thiscall destructor_hook(char a1);
	};

	int __thiscall SurfaceFRHook::draw_on_surface_hook(RECT* dest_rect, Surface* src_surface, RECT* src_rect, int* a5) {
		int ret = (this->*orig_draw_on_surface)(dest_rect, src_surface, src_rect, a5);
		//mod_loader->log_info("draw_on_surface: Surface (0x{:X})\n", reinterpret_cast<uintptr_t>(this));
		shared_renderer->on_surface_changed(this);
		return ret;
	}

	Surface* __thiscall SurfaceFRHook::destructor_hook(char a1) {
		shared_renderer->on_surface_destructed(this);
		(this->*orig_destructor)(a1);
		return this;
	}

	int(__thiscall Surface::* SurfaceFRHook::orig_draw_on_surface)(RECT* dest_rect, Surface* src_surface, RECT* src_rect, int* a5) = nullptr;
	Surface* (__thiscall Surface::* SurfaceFRHook::orig_destructor)(char a1) = nullptr;

	struct RxViewportHook {
		static int(__thiscall RxViewportHook::* orig_flash)(DWORD a2, int a3);
		static int(__cdecl *orig_set_flash_data)(int a1, int a2);

		BOOL __thiscall flash_hook(DWORD color, int duration) {
			mod_loader->log_info("RxViewport flash: color = #{:X}, duration = {}\n", color, duration);
			return (this->*orig_flash)(color, duration);
		}

		static int __cdecl set_flash_data_hook(int a1, int a2) {
			mod_loader->log_info("RxTilemap flash\n");
			return orig_set_flash_data(a1, a2);
		}
	};

	int(__thiscall RxViewportHook::* RxViewportHook::orig_flash)(DWORD a2, int a3) = nullptr;
	int(__cdecl* RxViewportHook::orig_set_flash_data)(int a1, int a2) = nullptr;

	void apply_fast_render() {
		if (!mod_loader->get_config().is_fast_render_enabled()) {
			mod_loader->log_info("FastRender disabled in config\n");
			return;
		}

		// Execute in postinit, because can't use LoadLibrary (used by glad and glfw) inside DllMain,
		// so call it after game initialization
		mod_loader->add_preinit_handler([] {
			int window_width = mod_loader->get_config().get_required_width();
			int window_height = mod_loader->get_config().get_required_height();

			GLFWwindow* window = GLRenderer::make_window(window_width, window_height);
			if (!window) {
				mod_loader->log_info("Failed to init window!\n");
				return;
			}
			shared_renderer = std::make_shared<GLRenderer>(window, window_width, window_height);

			mod_loader->hook_method(0x20FF0, &RxTilemapFRHook::update_data_hook, &RxTilemapFRHook::orig_update_data);
			mod_loader->hook_method(0x20FB0, &RxTilemapFRHook::set_surface_at_hook, &RxTilemapFRHook::orig_set_surface_at);
			mod_loader->hook_method(0x21150, &RxTilemapFRHook::tilemap_destructor_hook, &RxTilemapFRHook::orig_tilemap_destructor);
			mod_loader->hook_method(0x10E660, &ScreenFastRenderHook::update_screen_hook, &ScreenFastRenderHook::orig_update_screen);

			mod_loader->hook_method(0x1CE40, &RxSpriteFRHook::constructor_hook, &RxSpriteFRHook::orig_constructor);
			mod_loader->hook_method(0x1EFD0, &RxSpriteFRHook::destructor_hook, &RxSpriteFRHook::orig_destructor);
			mod_loader->hook_method(0x1D180, &RxSpriteFRHook::set_surface_hook, &RxSpriteFRHook::orig_set_surface);
			mod_loader->hook_method(0x1D230, &RxSpriteFRHook::update_data_hook, &RxSpriteFRHook::orig_update_data);

			mod_loader->hook_method(0x10BB00, &SurfaceFRHook::draw_on_surface_hook, &SurfaceFRHook::orig_draw_on_surface);
			mod_loader->hook_method(0x10B280, &SurfaceFRHook::destructor_hook, &SurfaceFRHook::orig_destructor);
			mod_loader->hook_method(0x20890, &SurfaceFRHook::destructor_hook, &SurfaceFRHook::orig_destructor);

			mod_loader->hook_method(0x1DFA0, &RxSpriteFRHook::flash_hook, &RxSpriteFRHook::orig_flash);
			mod_loader->hook_method(0x22820, &RxViewportHook::flash_hook, &RxViewportHook::orig_flash);
			mod_loader->hook_function(0x15820, &RxViewportHook::set_flash_data_hook, &RxViewportHook::orig_set_flash_data);
		});
	}
};

// end of FastRenderHooks warning silencing
#pragma warning(pop)
