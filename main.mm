// ANGLE (Metal) GLES3 uyumluluk testi (iOS).
// Bir D3D8->GLES3 uyumluluk katmaninin dayandigi ozellikleri tek tek sinar:
//   1 shader: #version 300 es, highp, ivec uniform, dallanma, discard
//   2 doku: RGBA8 + glGenerateMipmap (NPOT dahil) + anizotropik uzanti (varsa)
//   3 istemci bellegi: tampon bagli degilken glDrawArrays / glDrawElements (D3D8 DrawPrimitiveUP karsiligi)
//   4 tampon: VBO/IBO + glBufferSubData
//   5 stencil: 24/8 derinlik-stencil, maske cizimi (arayuz kirpma)
//   6 dokuya cizim: FBO + renk dokusu + derinlik renderbuffer
// Ekran 6 kareye bolunur: yesil = gecti, kirmizi = hata. Ayrintilar Documents/angle_test_log.txt (iTunes Dosya Paylasimi).
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <stdio.h>
#include <string.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

static FILE* g_pLog = NULL;
static void Log(const char* fmt, ...)
{
	char sz[1024];
	va_list a;
	va_start(a, fmt);
	vsnprintf(sz, sizeof(sz), fmt, a);
	va_end(a);
	NSLog(@"%s", sz);
	if (g_pLog) { fprintf(g_pLog, "%s\n", sz); fflush(g_pLog); }
}

static double NowMs()
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom) mach_timebase_info(&tb);
	return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static size_t ResidentMB()
{
	task_vm_info_data_t info;
	mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
	if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &n) != KERN_SUCCESS) return 0;
	return (size_t)(info.phys_footprint / (1024 * 1024));
}

// ---------------------------------------------------------------- shader
static const char* c_szVS =
	"#version 300 es\n"
	"precision highp float;\n"
	"layout(location = 0) in vec3 aPos;\n"
	"layout(location = 1) in vec2 aTex;\n"
	"layout(location = 2) in vec4 aColor;\n"
	"uniform mat4 uMVP;\n"
	"out vec2 vTex; out vec4 vColor;\n"
	"void main() { vTex = aTex; vColor = aColor.bgra; gl_Position = uMVP * vec4(aPos, 1.0); }\n";
static const char* c_szFS =
	"#version 300 es\n"
	"precision highp float;\n"
	"in vec2 vTex; in vec4 vColor;\n"
	"out vec4 FragColor;\n"
	"uniform sampler2D uTex;\n"
	"uniform ivec2 uUseTexture;\n"
	"uniform ivec3 uStage;\n"
	"uniform int uAlphaFunc;\n"
	"uniform float uAlphaRef;\n"
	"vec4 Op(int op, vec4 a, vec4 b) {\n"
	"  if (op == 2) return a; if (op == 3) return b;\n"
	"  if (op == 7) return clamp(a + b, 0.0, 1.0);\n"
	"  if (op == 13) return mix(b, a, b.a);\n"
	"  return a * b;\n"
	"}\n"
	"void main() {\n"
	"  vec4 t = uUseTexture.x != 0 ? texture(uTex, vTex).bgra : vec4(1.0);\n"
	"  vec4 c = Op(uStage.x, t, vColor);\n"
	"  if (uAlphaFunc == 5 && !(c.a > uAlphaRef)) discard;\n"
	"  FragColor = c;\n"
	"}\n";

static GLuint Compile(GLenum type, const char* src, bool* pOk)
{
	GLuint s = glCreateShader(type);
	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	GLint ok = 0;
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { char sz[1024]; glGetShaderInfoLog(s, sizeof(sz), NULL, sz); Log("shader hata: %s", sz); *pOk = false; }
	return s;
}

struct SVertex { float x, y, z, u, v; unsigned int color; };

@interface GLView : UIView
@end
@implementation GLView
+ (Class)layerClass { return [CAMetalLayer class]; }
@end

@interface TestController : UIViewController
@end

@implementation TestController {
	EGLDisplay _dpy; EGLSurface _surf; EGLContext _ctx; EGLConfig _cfg;
	CADisplayLink* _link;
	GLuint _prog, _tex, _vbo, _ibo, _fbo, _fboTex, _fboDepth;
	GLint _uMVP, _uUseTex, _uStage, _uAlphaFunc, _uAlphaRef;
	bool _ok[6];
	int _frames; double _t0, _sumFrame, _maxFrame, _last;
}

- (void)loadView { self.view = [[GLView alloc] initWithFrame:[UIScreen mainScreen].bounds]; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidAppear:(BOOL)animated
{
	[super viewDidAppear:animated];
	if (_dpy) return;
	CAMetalLayer* layer = (CAMetalLayer*)self.view.layer;
	layer.contentsScale = [UIScreen mainScreen].nativeScale;
	if (![self initEGL:layer]) { Log("EGL kurulamadi"); return; }
	[self runTests];
	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
	if (@available(iOS 15.0, *)) _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
	else _link.preferredFramesPerSecond = 60;
	[_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	_t0 = _last = NowMs();
}

- (BOOL)initEGL:(CAMetalLayer*)layer
{
	const EGLAttrib aDisplay[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
	_dpy = eglGetPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, (void*)EGL_DEFAULT_DISPLAY, aDisplay);
	if (_dpy == EGL_NO_DISPLAY || !eglInitialize(_dpy, NULL, NULL)) { Log("eglInitialize 0x%x", eglGetError()); return NO; }
	Log("EGL %s / %s", eglQueryString(_dpy, EGL_VENDOR), eglQueryString(_dpy, EGL_VERSION));
	// derinlik/stencil tercih sirasi: 24/8, 16/8, 16/0
	static const EGLint aDS[][2] = { { 24, 8 }, { 16, 8 }, { 16, 0 } };
	EGLint n = 0;
	for (int i = 0; i < 3 && n == 0; ++i) {
		const EGLint a[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
			EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_DEPTH_SIZE, aDS[i][0], EGL_STENCIL_SIZE, aDS[i][1], EGL_NONE };
		if (eglChooseConfig(_dpy, a, &_cfg, 1, &n) && n) Log("EGL config: depth %d stencil %d", aDS[i][0], aDS[i][1]);
	}
	if (!n) { Log("eglChooseConfig 0x%x", eglGetError()); return NO; }
	_surf = eglCreateWindowSurface(_dpy, _cfg, (__bridge EGLNativeWindowType)layer, NULL);
	const EGLint aCtx[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE };
	_ctx = eglCreateContext(_dpy, _cfg, EGL_NO_CONTEXT, aCtx);
	if (_surf == EGL_NO_SURFACE || _ctx == EGL_NO_CONTEXT || !eglMakeCurrent(_dpy, _surf, _surf, _ctx)) { Log("EGL yuzey/baglam 0x%x", eglGetError()); return NO; }
	eglSwapInterval(_dpy, 1);
	Log("GL %s | %s | %s", glGetString(GL_VERSION), glGetString(GL_RENDERER), glGetString(GL_SHADING_LANGUAGE_VERSION));
	return YES;
}

static bool GLOk(const char* c_szWhat)
{
	GLenum e = glGetError();
	if (e != GL_NO_ERROR) { Log("GL hata 0x%x: %s", e, c_szWhat); return false; }
	return true;
}

- (void)runTests
{
	// 1 shader
	bool ok = true;
	GLuint vs = Compile(GL_VERTEX_SHADER, c_szVS, &ok), fs = Compile(GL_FRAGMENT_SHADER, c_szFS, &ok);
	_prog = glCreateProgram();
	glAttachShader(_prog, vs); glAttachShader(_prog, fs); glLinkProgram(_prog);
	GLint linked = 0; glGetProgramiv(_prog, GL_LINK_STATUS, &linked);
	_ok[0] = ok && linked && GLOk("shader");
	_uMVP = glGetUniformLocation(_prog, "uMVP"); _uUseTex = glGetUniformLocation(_prog, "uUseTexture");
	_uStage = glGetUniformLocation(_prog, "uStage"); _uAlphaFunc = glGetUniformLocation(_prog, "uAlphaFunc");
	_uAlphaRef = glGetUniformLocation(_prog, "uAlphaRef");
	glUseProgram(_prog);
	glUniform1i(glGetUniformLocation(_prog, "uTex"), 0);

	// 2 doku: NPOT 300x200, mipmap + anizotropi
	const int W = 300, H = 200;
	unsigned int* px = (unsigned int*)malloc(W * H * 4);
	for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x)
		px[y * W + x] = (((x / 20 + y / 20) & 1) ? 0xFF2080E0u : 0xFFE0C040u);
	glGenTextures(1, &_tex); glBindTexture(GL_TEXTURE_2D, _tex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
	glGenerateMipmap(GL_TEXTURE_2D);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	const char* ext = (const char*)glGetString(GL_EXTENSIONS);
	if (ext && strstr(ext, "GL_EXT_texture_filter_anisotropic")) {
		float fMax = 1.0f; glGetFloatv(0x84FF, &fMax);
		glTexParameterf(GL_TEXTURE_2D, 0x84FE, fMax < 4.0f ? fMax : 4.0f);
		Log("anizotropik en cok %.0fx", fMax);
	}
	Log("ETC2 %s, ASTC %s, disjoint_timer_query %s",
		ext && strstr(ext, "GL_OES_compressed_ETC2") ? "var" : "uzanti listesinde yok (ES3 cekirdekte zorunlu)",
		ext && strstr(ext, "GL_KHR_texture_compression_astc_ldr") ? "var" : "yok",
		ext && strstr(ext, "GL_EXT_disjoint_timer_query") ? "var" : "yok");
	free(px);
	_ok[1] = GLOk("doku");

	// 4 tampon (3 cizimde sinanir)
	SVertex q[4] = { { -1, -1, 0, 0, 1, 0xFFFFFFFFu }, { 1, -1, 0, 1, 1, 0xFFFFFFFFu }, { 1, 1, 0, 1, 0, 0xFFFFFFFFu }, { -1, 1, 0, 0, 0, 0xFFFFFFFFu } };
	unsigned short idx[6] = { 0, 1, 2, 0, 2, 3 };
	glGenBuffers(1, &_vbo); glBindBuffer(GL_ARRAY_BUFFER, _vbo); glBufferData(GL_ARRAY_BUFFER, sizeof(q), q, GL_DYNAMIC_DRAW);
	glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(SVertex), &q[0]);
	glGenBuffers(1, &_ibo); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _ibo); glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(idx), idx, GL_STATIC_DRAW);
	glBindBuffer(GL_ARRAY_BUFFER, 0); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
	_ok[3] = GLOk("tampon");

	// 6 dokuya cizim
	glGenTextures(1, &_fboTex); glBindTexture(GL_TEXTURE_2D, _fboTex);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glGenRenderbuffers(1, &_fboDepth); glBindRenderbuffer(GL_RENDERBUFFER, _fboDepth);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, 256, 256);
	glGenFramebuffers(1, &_fbo); glBindFramebuffer(GL_FRAMEBUFFER, _fbo);
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, _fboTex, 0);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _fboDepth);
	_ok[5] = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE && GLOk("fbo");
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	Log("baslangic testleri: shader %d doku %d tampon %d fbo %d", _ok[0], _ok[1], _ok[3], _ok[5]);
	_ok[2] = _ok[4] = true;	// cizimde dogrulanir
}

- (void)setMVPx:(float)x y:(float)y s:(float)s
{
	const float m[16] = { s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, x, y, 0, 1 };
	glUniformMatrix4fv(_uMVP, 1, GL_FALSE, m);
}

- (void)attribs:(const unsigned char*)base
{
	glEnableVertexAttribArray(0); glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, sizeof(SVertex), base);
	glEnableVertexAttribArray(1); glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(SVertex), base + 12);
	glEnableVertexAttribArray(2); glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(SVertex), base + 20);
}

- (void)frame:(CADisplayLink*)link
{
	const double t = NowMs();
	const double dt = t - _last; _last = t;
	if (_frames > 0) { _sumFrame += dt; if (dt > _maxFrame) _maxFrame = dt; }
	++_frames;

	const CGSize sz = self.view.layer.bounds.size;
	const float sc = self.view.layer.contentsScale;
	const int w = (int)(sz.width * sc), h = (int)(sz.height * sc);

	// 6: FBO'ya dokulu kare ciz
	glBindFramebuffer(GL_FRAMEBUFFER, _fbo); glViewport(0, 0, 256, 256);
	glClearColor(0.1f, 0.6f, 0.2f, 1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glUseProgram(_prog); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, _tex);
	glUniform2i(_uUseTex, 1, 0); glUniform3i(_uStage, 4, 2, 0); glUniform1i(_uAlphaFunc, 8); glUniform1f(_uAlphaRef, 0.0f);
	[self setMVPx:0 y:0 s:0.8f];
	glBindBuffer(GL_ARRAY_BUFFER, _vbo); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _ibo);
	[self attribs:(const unsigned char*)0];
	glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, (void*)0);
	glBindFramebuffer(GL_FRAMEBUFFER, 0);
	if (_frames == 1) _ok[5] = _ok[5] && GLOk("fbo cizim");

	glViewport(0, 0, w, h);
	glClearColor(0.05f, 0.05f, 0.08f, 1); glClearStencil(0);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

	// 6 sonuc karesi: sol ust 3, sag alt 3; her karede kendi alt testinin cizimi
	for (int i = 0; i < 6; ++i) {
		const float cx = -0.66f + (i % 3) * 0.66f, cy = (i < 3) ? 0.45f : -0.45f;
		[self setMVPx:cx y:cy s:0.28f];
		SVertex v[4];
		const unsigned int col = _ok[i] ? 0xFF20C040u : 0xFFD02020u;	// BGRA -> shader .bgra
		const SVertex base[4] = { { -1, -1, 0, 0, 1, col }, { 1, -1, 0, 1, 1, col }, { 1, 1, 0, 1, 0, col }, { -1, 1, 0, 0, 0, col } };
		memcpy(v, base, sizeof(v));
		if (i == 4 && _frames < 3) {	// 5 stencil: kucuk kareyi maskele, sonra yalniz maskeye ciz
			glEnable(GL_STENCIL_TEST); glStencilFunc(GL_ALWAYS, 1, 0xFF); glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
			glColorMask(0, 0, 0, 0);
			[self setMVPx:cx y:cy s:0.14f];
			glBindBuffer(GL_ARRAY_BUFFER, 0); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
			[self attribs:(const unsigned char*)v]; glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
			glColorMask(1, 1, 1, 1); glStencilFunc(GL_EQUAL, 1, 0xFF); glStencilOp(GL_KEEP, GL_KEEP, GL_KEEP);
			[self setMVPx:cx y:cy s:0.28f];
		}
		if (i == 5) {	// dokuya cizilen sonucu goster
			glBindTexture(GL_TEXTURE_2D, _fboTex); glUniform2i(_uUseTex, 1, 0); glUniform3i(_uStage, 2, 2, 0);
		} else if (i == 1) {
			glBindTexture(GL_TEXTURE_2D, _tex); glUniform2i(_uUseTex, 1, 0); glUniform3i(_uStage, 13, 2, 0);
		} else {
			glUniform2i(_uUseTex, 0, 0); glUniform3i(_uStage, 3, 2, 0);
		}
		if (i == 2) {	// 3 istemci bellegi
			glBindBuffer(GL_ARRAY_BUFFER, 0); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
			unsigned short ii[6] = { 0, 1, 2, 0, 2, 3 };
			[self attribs:(const unsigned char*)v]; glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, ii);
		} else if (i == 3) {	// 4 tampon: kenar rengi SubData ile
			glBindBuffer(GL_ARRAY_BUFFER, _vbo); glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(v), v);
			glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, _ibo);
			[self attribs:(const unsigned char*)0]; glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, (void*)0);
		} else {
			glBindBuffer(GL_ARRAY_BUFFER, 0); glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
			[self attribs:(const unsigned char*)v]; glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
		}
		if (i == 4) glDisable(GL_STENCIL_TEST);
		if (_frames == 2 && !GLOk(i == 2 ? "istemci bellegi" : i == 3 ? "tampon cizim" : i == 4 ? "stencil" : "cizim")) _ok[i] = false;
	}
	if (!eglSwapBuffers(_dpy, _surf) && _frames < 5) Log("eglSwapBuffers 0x%x", eglGetError());

	if (t - _t0 >= 5000.0) {
		const int n = _frames - 1;
		Log("5 sn: %d kare, %.1f FPS, kare ort %.2f ms en kotu %.2f ms, bellek %zu MB, yuzey %dx%d | sonuc %d%d%d%d%d%d",
			n, n / ((t - _t0) / 1000.0), n ? _sumFrame / n : 0, _maxFrame, ResidentMB(), w, h, _ok[0], _ok[1], _ok[2], _ok[3], _ok[4], _ok[5]);
		_t0 = t; _frames = 1; _sumFrame = _maxFrame = 0;
	}
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow* window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts
{
	NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	g_pLog = fopen([[docs stringByAppendingPathComponent:@"angle_test_log.txt"] fileSystemRepresentation], "w");
	Log("ANGLE testi basladi: %s, iOS %s", [[UIDevice currentDevice].model UTF8String], [[UIDevice currentDevice].systemVersion UTF8String]);
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
	self.window.rootViewController = [TestController new];
	[self.window makeKeyAndVisible];
	return YES;
}
@end

int main(int argc, char* argv[])
{
	@autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
