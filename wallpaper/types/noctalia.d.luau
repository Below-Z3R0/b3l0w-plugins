-- Definiciones de tipos del host Noctalia para `luau-analyze --defs=types/noctalia.d.luau`.
-- No se empaqueta con el plugin: es solo una herramienta de validación local.

type Counters = { rc6: number, freq: number }

declare noctalia: {
	log: (string) -> (),
	notify: (string, string?) -> (),
	notifyError: (string, string?) -> (),
	nowMs: () -> number,

	readFile: (string) -> (string?, string?),
	writeFile: (string, string) -> (boolean, string?),
	fileExists: (string) -> boolean,
	fileInfo: (string) -> ({ size: number, mtime: number, isDir: boolean }?, string?),
	listDir: (string) -> ({ string }?, string?),
	mkdirAll: (string) -> (boolean, string?),
	removeFile: (string) -> (boolean, string?),
	renameFile: (string, string) -> (boolean, string?),
	expandPath: (string) -> string,

	pluginDir: () -> string?,
	pluginDataDir: () -> (string?, string?),

	-- El host: con el 2º argumento nil el proceso queda detached y devuelve
	-- si se pudo despachar (el timeout del 3º argumento se ignora). Con una
	-- función de callback devuelve la tabla del proceso y respeta el timeout.
	runAsync: ((string | { string }) -> boolean)
		& ((string | { string }, (string) -> (), number?) -> boolean),
	commandExists: (string) -> boolean,
	processMatches: ((boolean) -> (), ...string) -> boolean,

	getConfig: (string) -> any,
	getSetting: (string) -> any,
	getColor: (string) -> string?,
	isDarkMode: () -> boolean,
	setUpdateInterval: (number) -> (),

	outputs: () -> { { name: string, description: string, width: number, height: number, x: number, y: number, scale: number, focused: boolean } },
	focusedOutputName: () -> string?,
	setWallpaper: ((string) -> ()) & ((string, string) -> ()),
	setWallpaperEnabled: (string, boolean) -> (),

	tr: ((string) -> string) & ((string, { [string]: string }) -> string),
	trp: (string, number, { [string]: string }?) -> string,

	json: {
		decode: (string) -> (any?, string?),
		encode: ((any) -> (string?, string?)) & ((any, boolean) -> (string?, string?)),
	},

	string: {
		trim: (string) -> string,
		urlEncode: (string) -> string,
		urlDecode: (string) -> string,
	},

	state: {
		set: (string, any) -> (),
		get: (string) -> any,
		watch: (string, (any) -> ()) -> (),
	},

	togglePanel: (string) -> (),
	openSettings: () -> (),
}

declare ui: { [string]: (any?, any?) -> any }

declare type_Counters = Counters
