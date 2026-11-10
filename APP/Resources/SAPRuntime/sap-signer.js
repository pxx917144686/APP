(function (root) {
  "use strict";

  const CERTIFICATE_URL = "https://s.mzstatic.com/sap/setupCert.plist";
  const SETUP_URL = "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy";
  const SCRIPT_BASE_URL = (() => {
    const script = typeof document === "undefined" ? null : document.currentScript;
    const base = script && script.src
      ? script.src
      : (typeof document === "undefined" ? "./" : document.baseURI);
    return new URL(".", base).href;
  })();
  const DEFAULT_PROXY_URL = new URL("../proxy", SCRIPT_BASE_URL).href;
  const NATIVE_MEMORY_SHIMS = new Set([
    "_malloc", "_malloc_good_size", "_calloc", "_free",
    "_memcpy", "_memmove", "_memset", "___bzero",
    "___memcpy_chk", "___memset_chk", "_strlen", "_pthread_once",
    "_pthread_mutex_lock", "_pthread_mutex_unlock",
    "_pthread_rwlock_init", "_pthread_rwlock_init$UNIX2003",
    "_pthread_rwlock_unlock", "_pthread_rwlock_unlock$UNIX2003",
    "_pthread_rwlock_wrlock", "_pthread_rwlock_wrlock$UNIX2003"
  ]);

  let runtimePromise = null;
  let currentSigner = null;
  let kbsyncQueue = Promise.resolve();

  if (typeof WebAssembly === "object" && WebAssembly && WebAssembly.Table && WebAssembly.Table.prototype) {
    const rawTableSet = WebAssembly.Table.prototype.set;
    if (typeof rawTableSet === "function" && !rawTableSet._sapRealmSafe) {
      const safeTableSet = function (index, value) {
        try {
          return rawTableSet.call(this, index, value);
        } catch (err) {
          if (err && !(err instanceof TypeError) && err.name === "TypeError") {
            throw new TypeError(err.message);
          }
          throw err;
        }
      };
      safeTableSet._sapRealmSafe = true;
      try { WebAssembly.Table.prototype.set = safeTableSet; } catch (_) {}
    }
  }

  function loadScript(url) {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = url;
      script.onload = resolve;
      script.onerror = () => reject(new Error("load script failed: " + url));
      document.head.appendChild(script);
    });
  }

  function bytesToBase64(bytes) {
    let text = "";
    const chunkSize = 0x8000;
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      text += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
    }
    return btoa(text);
  }

  function base64ToBytes(value) {
    const text = atob(value);
    const bytes = new Uint8Array(text.length);
    for (let index = 0; index < text.length; index++) bytes[index] = text.charCodeAt(index);
    return bytes;
  }

  function unsigned64(value) {
    return BigInt.asUintN(64, BigInt(value));
  }

  function installShimBridge() {
    const registered = new Map();
    const nativeEntries = new Set();
    root.sapWasmShimHandled = false;

    root.sapWasmRegisterShim = (address, name) => {
      const value = BigInt(address);
      registered.set(value, name);
      if (NATIVE_MEMORY_SHIMS.has(name)) nativeEntries.add(value);
    };

    root.sapWasmShimName = address => registered.get(BigInt(address)) || null;

    root.sapWasmTrapHook = (handle, address) => {
      root.sapWasmShimHandled = false;
      const current = unsigned64(address);
      const name = registered.get(current);
      if (name && NATIVE_MEMORY_SHIMS.has(name)) return;
      if (!name) {
        for (const start of nativeEntries) {
          if (current > start && current < start + 64n) return;
        }
      }
      handle.emu_stop();
    };
  }

  async function initialize(options) {
    if (runtimePromise) return runtimePromise;

    runtimePromise = (async () => {
      const unicornURL = options.unicornURL || new URL("unicorn_x86.js", SCRIPT_BASE_URL).href;
      const wasmExecURL = options.wasmExecURL || new URL("wasm_exec.js", SCRIPT_BASE_URL).href;
      const wasmURL = options.wasmURL || new URL("sap.wasm", SCRIPT_BASE_URL).href;

      const timed = async (stage, operation) => {
        const logger = root.sapWasmKBSyncLog;
        if (typeof logger !== "function") return operation();
        logger(JSON.stringify({ event: "stageStart", stage }));
        const at = performance.now();
        try { return await operation(); }
        finally { logger(JSON.stringify({ event: "stageEnd", stage, durationMs: performance.now() - at })); }
      };
      if (typeof root.MUnicorn !== "function") await timed("runtime.unicorn.script", () => loadScript(unicornURL));
      if (typeof root.MUnicorn !== "function") throw new Error("Unicorn.js factory is unavailable");
      root.unicornModule = await timed("runtime.unicorn.instantiate", () => root.MUnicorn());
      if (!root.unicornModule) throw new Error("Unicorn.js initialization failed");

      installShimBridge();
      if (typeof root.Go !== "function") await timed("runtime.go.script", () => loadScript(wasmExecURL));
      if (typeof root.Go !== "function") throw new Error("Go WASM runtime is unavailable");

      const bytes = await timed("runtime.sap.fetch", async () => {
        const response = await fetch(wasmURL, { cache: "no-store" });
        if (!response.ok) throw new Error("load SAP WASM failed: " + response.status);
        return response.arrayBuffer();
      });
      const go = new root.Go();
      const compiled = await timed("runtime.sap.instantiate", () => WebAssembly.instantiate(bytes, go.importObject));
      go.run(compiled.instance);

      const deadline = Date.now() + 30000;
      while (!root.sapWasmSignerReady) {
        if (Date.now() >= deadline) throw new Error("SAP WASM initialization timed out");
        await new Promise(resolve => setTimeout(resolve, 10));
      }
    })();

    try {
      await runtimePromise;
    } catch (error) {
      runtimePromise = null;
      throw error;
    }
  }

  function proxyURL(proxyBase, upstream) {
    const target = new URL(proxyBase, document.baseURI);
    target.search = "";
    target.searchParams.set("url", upstream);
    return target.href;
  }

  async function requestCertificate(proxyBase) {
    const response = await fetch(proxyURL(proxyBase, CERTIFICATE_URL), { cache: "no-store" });
    if (!response.ok) throw new Error("fetch SAP setup certificate failed: " + response.status);
    return bytesToBase64(new Uint8Array(await response.arrayBuffer()));
  }

  async function exchangeSetup(proxyBase, requestBase64) {
    const response = await fetch(proxyURL(proxyBase, SETUP_URL), {
      method: "POST",
      headers: { "Content-Type": "application/x-plist" },
      body: base64ToBytes(requestBase64)
    });
    if (!response.ok) throw new Error("SAP setup request failed: " + response.status);
    return bytesToBase64(new Uint8Array(await response.arrayBuffer()));
  }

  class SapSigner {
    constructor(guid, options) {
      if (typeof guid !== "string" || guid.trim().length === 0) {
        throw new TypeError("guid must be a non-empty string");
      }

      this.guid = guid;
      this.options = options || {};
      this.queue = Promise.resolve();
      this.initialized = false;
    }

    enqueue(operation) {
      const result = this.queue.then(operation);
      this.queue = result.catch(() => {});
      return result;
    }

    initialize() {
      return this.enqueue(async () => {
        if (this.initialized) throw new Error("SAP signer is already initialized");
        await initialize(this.options);

        try {
          const proxyBase = this.options.proxyURL || DEFAULT_PROXY_URL;
          const certificate = await requestCertificate(proxyBase);
          const preparation = JSON.parse(root.sapWasmPrepareSetup(this.guid, certificate));
          if (preparation.error) throw new Error(preparation.error);

          const reply = await exchangeSetup(proxyBase, preparation.requestBase64);
          const completion = JSON.parse(root.sapWasmFinishSetup(reply));
          if (completion.error) throw new Error(completion.error);
          if (completion.ready !== true) throw new Error("SAP signer setup did not complete");

          this.initialized = true;
          return true;
        } catch (error) {
          root.sapWasmClose();
          throw error;
        }
      });
    }

    sign(bodyBase64) {
      return this.enqueue(async () => {
        if (!this.initialized) throw new Error("SAP signer is not initialized");
        if (typeof bodyBase64 !== "string" || bodyBase64.length === 0) {
          throw new TypeError("body Base64 must be a non-empty string");
        }

        const result = JSON.parse(root.sapWasmSign(bodyBase64));
        if (result.error) throw new Error(result.error);
        if (typeof result.signatureBase64 !== "string" || result.signatureBase64.length === 0) {
          throw new Error("SAP signer returned an empty signature");
        }

        return result.signatureBase64;
      });
    }

    close() {
      return this.enqueue(async () => {
        if (!this.initialized) return false;

        const result = JSON.parse(root.sapWasmClose());
        if (result.error) throw new Error(result.error);
        this.initialized = false;
        return true;
      });
    }
  }

  async function loadSapSigner(options) {
    await initialize(options || {});
    return true;
  }

  async function sapGenerateKBSync(guid, dsid, options) {
    if (typeof guid !== "string") throw new TypeError("guid must be a string");
    const normalizedGuid = guid.trim().replace(/:/g, "").toUpperCase();
    if (!/^[0-9A-F]{12}$/.test(normalizedGuid)) {
      throw new TypeError("kbsync GUID must contain exactly six hexadecimal bytes");
    }
    // Decimal strings and BigInts preserve the full uint64 DSID. A Number
    // is accepted only when JavaScript has represented it without rounding.
    if (typeof dsid === "number" && !Number.isSafeInteger(dsid)) {
      throw new TypeError("DSID numbers must be safe integers; use a decimal string for larger values");
    }
    if (!["string", "number", "bigint"].includes(typeof dsid)) {
      throw new TypeError("DSID must be a decimal string, safe integer, or BigInt");
    }
    const decimalDSID = String(dsid).trim();
    if (!/^[0-9]+$/.test(decimalDSID) || decimalDSID.length > 20) {
      throw new TypeError("DSID must be a nonzero decimal uint64");
    }
    const numericDSID = BigInt(decimalDSID);
    if (numericDSID === 0n || numericDSID > 0xffffffffffffffffn) {
      throw new TypeError("DSID must be a nonzero decimal uint64");
    }
    const execute = async () => {
      const profile = kbsyncProfiler(options || {});
      try {
        if (profile) profile.start("runtime.initialize");
        await initialize(options || {});
        if (profile) {
          profile.end("runtime.initialize");
          profile.instrument(root.unicornModule);
        }
        const result = JSON.parse(root.sapWasmGenerateKBSync(normalizedGuid, String(numericDSID)));
        if (result.error) throw new Error(result.error);
        if (typeof result.kbsyncBase64 !== "string" || result.kbsyncBase64.length === 0) {
          throw new Error("StoreAgent returned an empty kbsync");
        }
        return result.kbsyncBase64;
      } catch (error) {
        if (profile) profile.data.error = String(error);
        throw error;
      } finally {
        if (profile) profile.finish();
      }
    };
    const pending = kbsyncQueue.then(execute);
    kbsyncQueue = pending.catch(() => {});
    return pending;
  }

  function kbsyncProfiler(options) {
    if (!options.debug && typeof options.onDebug !== "function") return null;
    const started = performance.now();
    const previousLogger = root.sapWasmKBSyncLog;
    const previousChunk = root.sapWasmInstructionChunk;
    if (options.instructionChunk !== undefined) {
      if (!Number.isSafeInteger(options.instructionChunk) || options.instructionChunk <= 0) {
        throw new TypeError("instructionChunk must be a positive safe integer");
      }
      root.sapWasmInstructionChunk = options.instructionChunk;
    }
    let originalConstructor = null;
    let module = null;
    let phase = "runtime.initialize";
    const starts = new Map();
    const data = { backend: "wasm-tci", stages: {}, engines: [], segments: [], events: [] };
    const emit = event => {
      event.elapsedMs = performance.now() - started;
      data.events.push(event);
      if (options.debug) console.debug("[kbsync]", JSON.stringify(event));
      if (typeof options.onDebug === "function") {
        try { options.onDebug(event); } catch (_) { /* Diagnostics must not interrupt guest execution. */ }
      }
    };
    root.sapWasmKBSyncLog = value => {
      const event = JSON.parse(value);
      if (event.event === "stageStart") phase = event.stage;
      if (event.event === "stageEnd") data.stages[event.stage] = event.durationMs;
      emit(event);
    };
    return {
      data,
      start(name) {
        starts.set(name, performance.now());
        phase = name;
        emit({ event: "stageStart", stage: name });
      },
      end(name) {
        const durationMs = performance.now() - starts.get(name);
        data.stages[name] = durationMs;
        emit({ event: "stageEnd", stage: name, durationMs });
      },
      instrument(runtime) {
        data.backend = runtime.sapRuntimeBackend || "wasm-tci";
        data.build = runtime.sapRuntimeBuild || "unspecified";
        emit({ event: "runtime", backend: data.backend, build: data.build });
        module = runtime;
        originalConstructor = module.Unicorn;
        module.Unicorn = function (...arguments_) {
          const opening = performance.now();
          const engine = new originalConstructor(...arguments_);
          const stats = { id: data.engines.length + 1, openMs: performance.now() - opening, calls: {}, closed: false };
          data.engines.push(stats);
          const originalRead = engine.reg_read_i64;
          for (const name of ["emu_start", "mem_map", "mem_write", "mem_read", "reg_read_i64", "reg_write_i64", "hook_add", "hook_del", "ctl_set_tcg_buffer_size", "close"]) {
            const original = engine[name];
            engine[name] = function (...args) {
              const at = performance.now();
              let failure = null;
              try {
                const result = original.apply(this, args);
                if (name === "close") stats.closed = true;
                return result;
              } catch (error) {
                failure = String(error);
                throw error;
              } finally {
                const durationMs = performance.now() - at;
                const call = stats.calls[name] || (stats.calls[name] = { count: 0, durationMs: 0, bytes: 0 });
                call.count++;
                call.durationMs += durationMs;
                if (name === "mem_write") call.bytes += args[1].length;
                if (name === "mem_read" || name === "mem_map") call.bytes += Number(args[1]);
                if (name === "emu_start") {
                  const event = { event: "segment", stage: phase, engine: stats.id,
                    begin: "0x" + BigInt.asUintN(64, args[0]).toString(16),
                    durationMs };
                  if (module.sapTciJitStats) event.jit = { ...module.sapTciJitStats };
                  try {
                    const rip = originalRead.call(this, module.X86_REG_RIP);
                    event.end = "0x" + BigInt.asUintN(64, rip).toString(16);
                    event.stop = root.sapWasmShimName ? root.sapWasmShimName(rip) : null;
                  } catch (error) { event.diagnosticError = String(error); }
                  if (failure) event.error = failure;
                  data.segments.push(event);
                  emit(event);
                }
              }
            };
          }
          return engine;
        };
        module.Unicorn.prototype = originalConstructor.prototype;
      },
      finish() {
        if (module) module.Unicorn = originalConstructor;
        root.sapWasmKBSyncLog = previousLogger;
        root.sapWasmInstructionChunk = previousChunk;
        data.totalMs = performance.now() - started;
        root.sapKBSyncLastProfile = data;
        emit({ event: "summary", durationMs: data.totalMs, stages: data.stages, engines: data.engines });
      }
    };
  }

  async function createSapSigner(guid, options) {
    const signer = new SapSigner(guid, options || {});
    await signer.initialize();
    return signer;
  }

  function sapInitialize(guid, options) {
    if (currentSigner) return Promise.reject(new Error("SAP signer is already initialized"));
    currentSigner = new SapSigner(guid, options || {});
    return currentSigner.initialize().catch(error => {
      currentSigner = null;
      throw error;
    });
  }

  function sapSign(bodyBase64) {
    if (!currentSigner) return Promise.reject(new Error("SAP signer is not initialized"));
    return currentSigner.sign(bodyBase64);
  }

  // Compatibility/control path matching the original one-shot ordering:
  // setup completion and body signing happen inside one Go/WASM call, then
  // the signer state is destroyed immediately.
  function sapSignOnce(guid, bodyBase64, options) {
    return (async () => {
      if (typeof bodyBase64 !== "string" || bodyBase64.length === 0) {
        throw new TypeError("body Base64 must be a non-empty string");
      }

      const signer = new SapSigner(guid, options || {});
      try {
        await initialize(signer.options);
        const proxyBase = signer.options.proxyURL || DEFAULT_PROXY_URL;
        const certificate = await requestCertificate(proxyBase);
        const preparation = JSON.parse(root.sapWasmPrepareSetup(signer.guid, certificate, bodyBase64));
        if (preparation.error) throw new Error(preparation.error);
        const reply = await exchangeSetup(proxyBase, preparation.requestBase64);
        const result = JSON.parse(root.sapWasmFinishSetupAndSign(reply));
        if (result.error) throw new Error(result.error);
        return result.signatureBase64;
      } finally {
        root.sapWasmClose();
      }
    })();
  }

  function sapClose() {
    if (!currentSigner) return Promise.resolve(false);
    const signer = currentSigner;
    currentSigner = null;
    return signer.close();
  }

  const FINISH_URL = "https://auth.itunes.apple.com/auth/v1/otp/1.5/finish";
  const STORE_SCOPE = -1n;
  const NOT_PROVISIONED_CODE = -45061;
  const textEncoder = new TextEncoder();
  const textDecoder = new TextDecoder("utf-8");

  let storeProofQueue = Promise.resolve();
  let storeLibraryCache = null;
  let storeRuntimeInstance = null;

  function strictBase64ToBytes(value, stripSpace) {
    if (typeof value !== "string") throw new TypeError("Expected base64 string");
    const clean = stripSpace ? value.replace(/[\s]+/g, "") : value;
    if (clean.length === 0 || clean.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(clean)) {
      throw new Error("Invalid base64 encoding");
    }
    const decoded = base64ToBytes(clean);
    if (decoded.length === 0 || bytesToBase64(decoded) !== clean) {
      throw new Error("Invalid canonical base64 encoding");
    }
    return decoded;
  }

  function decodeXmlEntities(text) {
    return text.replace(/&(#x[0-9a-fA-F]+|#[0-9]+|lt|gt|amp|quot|apos);/g, (_, entity) => {
      if (entity === "lt") return "<";
      if (entity === "gt") return ">";
      if (entity === "amp") return "&";
      if (entity === "quot") return "\"";
      if (entity === "apos") return "'";
      const code = entity.startsWith("#x") ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : "";
    });
  }

  function escapeXml(text) {
    return String(text)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&apos;");
  }

  function encodeFinishPlist(clientDataBase64, guid) {
    return [
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
      '<plist version="1.0"><dict>',
      "<key>clientData</key><string>" + escapeXml(clientDataBase64) + "</string>",
      "<key>guid</key><string>" + escapeXml(guid) + "</string>",
      "</dict></plist>"
    ].join("");
  }

  function parseXmlPlistDict(xmlText) {
    if (typeof xmlText !== "string" || xmlText.length === 0) throw new Error("Empty plist response");
    const lower = xmlText.slice(0, 512).toLowerCase();
    if (lower.includes("<html") || lower.includes("<script")) throw new Error("Unexpected HTML response");

    const tokens = [];
    const pattern = /<!--[\s\S]*?-->|<!\[CDATA\[([\s\S]*?)\]\]>|<\?[\s\S]*?\?>|<!DOCTYPE[\s\S]*?>|<\/?([A-Za-z0-9_:-]+)(?:\s[^>]*)?>|([^<]+)/g;
    let match;
    while ((match = pattern.exec(xmlText)) !== null) {
      const full = match[0];
      if (full.startsWith("<!--") || full.startsWith("<?") || full.startsWith("<!DOCTYPE")) continue;
      if (match[1] !== undefined) {
        tokens.push({ kind: "text", value: match[1] });
      } else if (match[2] !== undefined) {
        const selfClosing = full.endsWith("/>");
        const closing = full.startsWith("</");
        tokens.push({ kind: closing ? "close" : (selfClosing ? "empty" : "open"), tag: match[2] });
      } else if (match[3] !== undefined) {
        tokens.push({ kind: "text", value: decodeXmlEntities(match[3]) });
      }
    }

    let pos = 0;
    function readTextUntil(closeTag) {
      let acc = "";
      while (pos < tokens.length) {
        const tok = tokens[pos++];
        if (tok.kind === "close" && tok.tag === closeTag) return acc;
        if (tok.kind === "text") acc += tok.value;
      }
      throw new Error("Unterminated tag: " + closeTag);
    }

    function parseValue() {
      while (pos < tokens.length && tokens[pos].kind === "text" && tokens[pos].value.trim() === "") pos++;
      if (pos >= tokens.length) throw new Error("Unexpected end of plist");
      const tok = tokens[pos++];
      if (tok.kind === "empty") {
        if (tok.tag === "true") return true;
        if (tok.tag === "false") return false;
        if (tok.tag === "string" || tok.tag === "data") return "";
        if (tok.tag === "dict") return {};
        if (tok.tag === "array") return [];
        return null;
      }
      if (tok.kind !== "open") throw new Error("Unexpected plist token");
      if (tok.tag === "string" || tok.tag === "data") return readTextUntil(tok.tag);
      if (tok.tag === "integer" || tok.tag === "real" || tok.tag === "date") return readTextUntil(tok.tag).trim();
      if (tok.tag === "dict") {
        const out = {};
        while (pos < tokens.length) {
          while (pos < tokens.length && tokens[pos].kind === "text" && tokens[pos].value.trim() === "") pos++;
          if (pos >= tokens.length) throw new Error("Unterminated dict");
          if (tokens[pos].kind === "close" && tokens[pos].tag === "dict") { pos++; return out; }
          const keyTok = tokens[pos++];
          if (keyTok.tag !== "key") throw new Error("Expected plist key");
          const key = keyTok.kind === "empty" ? "" : readTextUntil("key");
          out[key] = parseValue();
        }
        throw new Error("Unterminated dict");
      }
      if (tok.tag === "array") {
        const arr = [];
        while (pos < tokens.length) {
          while (pos < tokens.length && tokens[pos].kind === "text" && tokens[pos].value.trim() === "") pos++;
          if (pos >= tokens.length) throw new Error("Unterminated array");
          if (tokens[pos].kind === "close" && tokens[pos].tag === "array") { pos++; return arr; }
          arr.push(parseValue());
        }
        throw new Error("Unterminated array");
      }
      readTextUntil(tok.tag);
      return null;
    }

    for (let i = 0; i < tokens.length; i++) {
      if ((tokens[i].kind === "open" || tokens[i].kind === "empty") && tokens[i].tag === "dict") {
        pos = i;
        const parsed = parseValue();
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) return parsed;
      }
    }
    throw new Error("No dictionary found in plist");
  }

  function parseInputState(stateJson) {
    if (typeof stateJson !== "string" || stateJson.trim().length === 0) {
      throw new TypeError("stateJson must be a non-empty JSON string");
    }
    const parsed = JSON.parse(stateJson);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new TypeError("Invalid Store state object");
    }
    if (typeof parsed.identifier !== "string" || !/^[0-9a-fA-F]{16}$/.test(parsed.identifier)) {
      throw new TypeError("Store identifier must be 16 hexadecimal characters");
    }
    const identifier = parsed.identifier.toLowerCase();
    const rawFiles = parsed.files === undefined ? {} : parsed.files;
    if (!rawFiles || typeof rawFiles !== "object" || Array.isArray(rawFiles)) {
      throw new TypeError("Store files must be an object");
    }
    const files = new Map();
    for (const [name, encoded] of Object.entries(rawFiles)) {
      if (!name || name.length > 128 || name.includes("/") || name.includes("\\") || name === "." || name === "..") {
        throw new Error("Unsafe Store state filename");
      }
      if (typeof encoded !== "string") throw new TypeError("Store file data must be base64");
      files.set("/adi/" + name, encoded.length === 0 ? new Uint8Array(0) : strictBase64ToBytes(encoded, false));
    }
    return { identifier, files };
  }

  async function fetchStoreLibraries(options) {
    if (storeLibraryCache) return storeLibraryCache;
    const coreURL = (options && options.coreAdiURL) || new URL("libCoreADI.so", SCRIPT_BASE_URL).href;
    const sscURL = (options && options.sscURL) || new URL("libstoreservicescore.so", SCRIPT_BASE_URL).href;
    storeLibraryCache = (async () => {
      const [coreResp, sscResp] = await Promise.all([
        fetch(coreURL, { cache: "no-store" }),
        fetch(sscURL, { cache: "no-store" })
      ]);
      if (!coreResp.ok) throw new Error("Failed to load libCoreADI.so: " + coreResp.status);
      if (!sscResp.ok) throw new Error("Failed to load libstoreservicescore.so: " + sscResp.status);
      const [coreBuf, sscBuf] = await Promise.all([coreResp.arrayBuffer(), sscResp.arrayBuffer()]);
      return { coreBytes: new Uint8Array(coreBuf), sscBytes: new Uint8Array(sscBuf) };
    })();
    try {
      return await storeLibraryCache;
    } catch (err) {
      storeLibraryCache = null;
      throw err;
    }
  }

  function parseSharedObject(bytes) {
    if (bytes.length < 64 || bytes[0] !== 0x7f || bytes[1] !== 0x45 || bytes[2] !== 0x4c || bytes[3] !== 0x46) {
      throw new Error("Invalid shared library header");
    }
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (bytes[4] !== 2 || bytes[5] !== 1 || view.getUint16(18, true) !== 62) {
      throw new Error("Unsupported shared library architecture");
    }
    const phoff = Number(view.getBigUint64(32, true));
    const shoff = Number(view.getBigUint64(40, true));
    const phentsize = view.getUint16(54, true);
    const phnum = view.getUint16(56, true);
    const shentsize = view.getUint16(58, true);
    const shnum = view.getUint16(60, true);

    const segments = [];
    for (let i = 0; i < phnum; i++) {
      const off = phoff + i * phentsize;
      if (view.getUint32(off, true) !== 1) continue;
      const pOffset = Number(view.getBigUint64(off + 8, true));
      const pVaddr = Number(view.getBigUint64(off + 16, true));
      const pFilesz = Number(view.getBigUint64(off + 32, true));
      const pMemsz = Number(view.getBigUint64(off + 40, true));
      if (pOffset + pFilesz > bytes.length) throw new Error("Segment exceeds library bounds");
      segments.push({ pOffset, pVaddr, pFilesz, pMemsz });
    }

    const sections = [];
    for (let i = 0; i < shnum; i++) {
      const off = shoff + i * shentsize;
      sections.push({
        type: view.getUint32(off + 4, true),
        offset: Number(view.getBigUint64(off + 24, true)),
        size: Number(view.getBigUint64(off + 32, true)),
        link: view.getUint32(off + 40, true)
      });
    }

    const dynsym = sections.find(s => s.type === 11);
    if (!dynsym || !sections[dynsym.link]) throw new Error("Missing dynamic symbol table");
    const dynstr = sections[dynsym.link];
    const symbols = [];
    for (let off = dynsym.offset; off + 24 <= dynsym.offset + dynsym.size; off += 24) {
      const nameOff = view.getUint32(off, true);
      const shndx = view.getUint16(off + 6, true);
      const value = Number(view.getBigUint64(off + 8, true));
      let end = dynstr.offset + nameOff;
      while (end < bytes.length && bytes[end] !== 0) end++;
      const name = textDecoder.decode(bytes.subarray(dynstr.offset + nameOff, end));
      symbols.push({ name, shndx, value });
    }

    const relocations = [];
    for (const sec of sections) {
      if (sec.type === 9) throw new Error("Unsupported REL table");
      if (sec.type !== 4) continue;
      for (let off = sec.offset; off + 24 <= sec.offset + sec.size; off += 24) {
        const rOffset = Number(view.getBigUint64(off, true));
        const rInfo = view.getBigUint64(off + 8, true);
        const rAddend = Number(view.getBigInt64(off + 16, true));
        relocations.push({
          offset: rOffset,
          symIdx: Number(rInfo >> 32n),
          type: Number(rInfo & 0xffffffffn),
          addend: rAddend
        });
      }
    }

    return { segments, symbols, relocations };
  }

  async function createStoreRuntime(identifier, initialFiles, options) {
    const unicornURL = (options && options.unicornURL) || new URL("unicorn_x86.js", SCRIPT_BASE_URL).href;
    if (typeof root.MUnicorn !== "function") await loadScript(unicornURL);
    if (typeof root.MUnicorn !== "function") throw new Error("Unicorn runtime factory is unavailable");

    const { coreBytes, sscBytes } = await fetchStoreLibraries(options);
    const mod = await root.MUnicorn();
    const engine = new mod.Unicorn(mod.ARCH_X86, mod.MODE_64);
    engine.ctl_set_tcg_buffer_size(16 * 1024 * 1024);

    const pageSize = 0x1000;
    const alignDown = n => Math.floor(n / pageSize) * pageSize;
    const alignUp = n => Math.ceil(n / pageSize) * pageSize;

    const stackAddr = 0x70000000, stackBytes = 0x00200000;
    const tlsAddr = 0x60000000, tlsBytes = 0x00010000;
    const shimAddr = 0x30000000, shimBytes = 0x00010000;
    const heapAddr = 0x40000000, heapBytes = 0x04000000;

    engine.mem_map(stackAddr, stackBytes, mod.PROT_ALL);
    engine.mem_map(tlsAddr, tlsBytes, mod.PROT_ALL);
    engine.mem_map(shimAddr, shimBytes, mod.PROT_ALL);
    engine.mem_map(heapAddr, heapBytes, mod.PROT_ALL);

    // Expand temporary frame capacity after mem_map triggers guest context initialization.
    const handleVal = mod.getValue(engine.handle_ptr, "*");
    const cpuVal = mod.getValue(handleVal + 432, "*");
    const ctxVal = mod.getValue(handleVal + 452, "*");
    if (!cpuVal || !ctxVal) throw new Error("Guest execution context was not initialized");
    const envVal = mod.getValue(cpuVal + 33028, "*");
    const tempBase = mod.getValue(ctxVal + 76, "*");
    const frameCap = 65536;
    const frameBuf = mod._malloc(frameCap);
    if (!frameBuf) throw new Error("Failed to allocate guest temp frame");
    const frameRel = (frameBuf - envVal) | 0;
    mod.setValue(ctxVal + 64, frameRel, "i32");
    mod.setValue(ctxVal + 68, frameRel, "i32");
    mod.setValue(ctxVal + 72, (frameRel + frameCap) | 0, "i32");
    mod.setValue(ctxVal + 76, tempBase + 40, "*");

    const fsBase = tlsAddr + 0x1000;
    engine.reg_write_i64(mod.X86_REG_FS_BASE, BigInt(fsBase));
    const tlsInit = new Uint8Array(0x100);
    const tlsView = new DataView(tlsInit.buffer);
    tlsView.setBigUint64(0, BigInt(fsBase), true);
    tlsView.setBigUint64(0x28, 0x1122334455667788n, true);
    engine.mem_write(fsBase, tlsInit);

    const errnoAddr = tlsAddr + 0x2000;
    const returnStub = shimAddr + 0xfff0;
    const trapStub = shimAddr + 0xffe0;
    const retFill = new Uint8Array(shimBytes);
    retFill.fill(0xc3);
    engine.mem_write(shimAddr, retFill);

    let nextShim = shimAddr;
    const shimByName = new Map();
    const shimByAddr = new Map();
    function addShim(name, handler) {
      const addr = nextShim;
      nextShim += 16;
      shimByName.set(name, addr);
      shimByAddr.set(addr, { name, handler });
    }

    let heapCursor = heapAddr + 0x1000;
    const freeList = [];
    const ALLOC_MAGIC = 0x53545241;
    const FREE_MAGIC = 0x53545246;
    function guestAlloc(size) {
      const aligned = Math.max(16, Math.ceil(Math.max(1, size) / 16) * 16);
      for (let i = 0; i < freeList.length; i++) {
        if (freeList[i].size >= aligned && freeList[i].size <= aligned + 256) {
          const reused = freeList.splice(i, 1)[0];
          const hdr = new Uint8Array(16);
          const hdrView = new DataView(hdr.buffer);
          hdrView.setBigUint64(0, BigInt(reused.size), true);
          hdrView.setUint32(8, ALLOC_MAGIC, true);
          engine.mem_write(reused.addr - 16, hdr);
          engine.mem_write(reused.addr, new Uint8Array(aligned));
          return reused.addr;
        }
      }
      const hdrAddr = heapCursor;
      const userAddr = hdrAddr + 16;
      heapCursor = userAddr + aligned;
      if (heapCursor >= heapAddr + heapBytes) throw new Error("Guest heap exhausted");
      const hdr = new Uint8Array(16);
      const hdrView = new DataView(hdr.buffer);
      hdrView.setBigUint64(0, BigInt(aligned), true);
      hdrView.setUint32(8, ALLOC_MAGIC, true);
      engine.mem_write(hdrAddr, hdr);
      return userAddr;
    }

    function guestFree(addr) {
      if (!addr || addr < heapAddr + 16 || addr >= heapAddr + heapBytes || (addr & 15) !== 0) return;
      const hdr = new Uint8Array(engine.mem_read(addr - 16, 16));
      const hdrView = new DataView(hdr.buffer, hdr.byteOffset, 16);
      const size = Number(hdrView.getBigUint64(0, true));
      const magic = hdrView.getUint32(8, true);
      if (magic !== ALLOC_MAGIC || size < 16 || size >= heapBytes) return;
      hdrView.setUint32(8, FREE_MAGIC, true);
      engine.mem_write(addr - 16, hdr);
      freeList.push({ addr, size });
    }

    function readGuestString(addr) {
      if (!addr) return "";
      const parts = [];
      let cur = addr;
      while (true) {
        const step = Math.min(64, pageSize - (cur % pageSize));
        const chunk = new Uint8Array(engine.mem_read(cur, step));
        const zeroIdx = chunk.indexOf(0);
        if (zeroIdx !== -1) {
          parts.push(chunk.subarray(0, zeroIdx));
          break;
        }
        parts.push(chunk);
        cur += step;
        if (cur - addr > 4096) throw new Error("Guest string exceeds path limit");
      }
      let total = 0;
      for (const p of parts) total += p.length;
      const merged = new Uint8Array(total);
      let offset = 0;
      for (const p of parts) { merged.set(p, offset); offset += p.length; }
      return textDecoder.decode(merged);
    }

    function writeErrno(code) {
      const buf = new Uint8Array(4);
      new DataView(buf.buffer).setInt32(0, code, true);
      engine.mem_write(errnoAddr, buf);
    }

    const vfsFiles = new Map();
    for (const [k, v] of initialFiles.entries()) vfsFiles.set(k, new Uint8Array(v));
    const vfsDirs = new Set(["/", "/adi"]);
    const openFds = new Map();
    let nextFd = 10;

    function normalizePath(p) {
      return p.replace(/\/+/g, "/").replace(/\/$/, "") || "/";
    }

    function writeStatStruct(stAddr, isDir, byteLength) {
      const st = new Uint8Array(144);
      const view = new DataView(st.buffer);
      view.setBigUint64(0, 1n, true);
      view.setBigUint64(8, 1n, true);
      view.setBigUint64(16, 1n, true);
      view.setUint32(24, isDir ? 0o040777 : 0o100644, true);
      view.setBigInt64(48, BigInt(byteLength), true);
      view.setBigInt64(56, 4096n, true);
      view.setBigInt64(64, BigInt(Math.ceil(byteLength / 512)), true);
      const nowSec = BigInt(Math.floor(Date.now() / 1000));
      view.setBigInt64(72, nowSec, true);
      view.setBigInt64(88, nowSec, true);
      view.setBigInt64(104, nowSec, true);
      engine.mem_write(stAddr, st);
    }

    const zeroStub = () => 0n;
    for (const name of [
      "pthread_once", "pthread_create", "pthread_mutex_lock", "pthread_mutex_unlock",
      "pthread_rwlock_init", "pthread_rwlock_destroy", "pthread_rwlock_rdlock",
      "pthread_rwlock_wrlock", "pthread_rwlock_unlock", "__cxa_atexit", "__cxa_finalize",
      "umask", "chmod", "dlclose"
    ]) {
      addShim(name, zeroStub);
    }

    addShim("__errno", () => BigInt(errnoAddr));
    addShim("malloc", rdi => BigInt(guestAlloc(Number(rdi))));
    addShim("free", rdi => { guestFree(Number(rdi)); return 0n; });

    addShim("strncpy", (rdi, rsi, rdx) => {
      const dst = Number(rdi), src = Number(rsi), limit = Number(rdx);
      if (limit > 0) {
        const out = new Uint8Array(limit);
        let copied = 0;
        while (copied < limit) {
          const cur = src + copied;
          const step = Math.min(limit - copied, pageSize - (cur % pageSize), 128);
          const chunk = new Uint8Array(engine.mem_read(cur, step));
          const zeroIdx = chunk.indexOf(0);
          if (zeroIdx !== -1) {
            out.set(chunk.subarray(0, zeroIdx), copied);
            break;
          }
          out.set(chunk, copied);
          copied += step;
        }
        engine.mem_write(dst, out);
      }
      return rdi;
    });

    addShim("__system_property_get", (rdi, rsi) => {
      const prop = textEncoder.encode("no s/n number\0");
      engine.mem_write(Number(rsi), prop);
      return BigInt(prop.length - 1);
    });

    addShim("arc4random", () => {
      const rand = new Uint32Array(1);
      crypto.getRandomValues(rand);
      return BigInt(rand[0]);
    });

    addShim("gettimeofday", rdi => {
      const tv = Number(rdi);
      if (tv) {
        const now = Date.now();
        const buf = new Uint8Array(16);
        const view = new DataView(buf.buffer);
        view.setBigInt64(0, BigInt(Math.floor(now / 1000)), true);
        view.setBigInt64(8, BigInt((now % 1000) * 1000), true);
        engine.mem_write(tv, buf);
      }
      return 0n;
    });

    addShim("mkdir", rdi => {
      const p = normalizePath(readGuestString(Number(rdi)));
      if (vfsDirs.has(p) || vfsFiles.has(p)) {
        writeErrno(17);
        return -1n;
      }
      vfsDirs.add(p);
      return 0n;
    });

    addShim("lstat", (rdi, rsi) => {
      const p = normalizePath(readGuestString(Number(rdi)));
      const stAddr = Number(rsi);
      if (vfsDirs.has(p)) { writeStatStruct(stAddr, true, 4096); return 0n; }
      if (vfsFiles.has(p)) { writeStatStruct(stAddr, false, vfsFiles.get(p).length); return 0n; }
      writeErrno(2);
      return -1n;
    });

    addShim("fstat", (rdi, rsi) => {
      const entry = openFds.get(Number(rdi));
      if (!entry) { writeErrno(9); return -1n; }
      if (entry.isDir || vfsDirs.has(entry.path)) {
        writeStatStruct(Number(rsi), true, 4096);
        return 0n;
      }
      const data = vfsFiles.get(entry.path) || new Uint8Array(0);
      writeStatStruct(Number(rsi), false, data.length);
      return 0n;
    });

    addShim("open", (rdi, rsi) => {
      const p = normalizePath(readGuestString(Number(rdi)));
      const flags = Number(rsi);
      const accMode = flags & 3;
      const flagCreat = 64, flagExcl = 128, flagTrunc = 512, flagAppend = 1024;
      if (vfsDirs.has(p)) {
        if (accMode !== 0 || (flags & (flagCreat | flagTrunc))) {
          writeErrno(21);
          return -1n;
        }
        const fd = nextFd++;
        openFds.set(fd, { path: p, pos: 0, flags, isDir: true });
        return BigInt(fd);
      }
      if (vfsFiles.has(p)) {
        if ((flags & flagCreat) && (flags & flagExcl)) { writeErrno(17); return -1n; }
        if (flags & flagTrunc) vfsFiles.set(p, new Uint8Array(0));
      } else if (flags & flagCreat) {
        vfsFiles.set(p, new Uint8Array(0));
      } else {
        writeErrno(2);
        return -1n;
      }
      const fd = nextFd++;
      const curLen = vfsFiles.get(p).length;
      openFds.set(fd, { path: p, pos: (flags & flagAppend) ? curLen : 0, flags, isDir: false });
      return BigInt(fd);
    });

    addShim("close", rdi => {
      openFds.delete(Number(rdi));
      return 0n;
    });

    addShim("ftruncate", (rdi, rsi) => {
      const entry = openFds.get(Number(rdi));
      if (!entry) { writeErrno(9); return -1n; }
      const targetLen = Number(rsi);
      const cur = vfsFiles.get(entry.path) || new Uint8Array(0);
      if (targetLen < cur.length) {
        vfsFiles.set(entry.path, cur.slice(0, targetLen));
      } else if (targetLen > cur.length) {
        const next = new Uint8Array(targetLen);
        next.set(cur, 0);
        vfsFiles.set(entry.path, next);
      }
      return 0n;
    });

    addShim("read", (rdi, rsi, rdx) => {
      const entry = openFds.get(Number(rdi));
      if (!entry) { writeErrno(9); return -1n; }
      const data = vfsFiles.get(entry.path) || new Uint8Array(0);
      const count = Math.min(Number(rdx), Math.max(0, data.length - entry.pos));
      if (count > 0) {
        engine.mem_write(Number(rsi), data.subarray(entry.pos, entry.pos + count));
        entry.pos += count;
      }
      return BigInt(count);
    });

    addShim("write", (rdi, rsi, rdx) => {
      const entry = openFds.get(Number(rdi));
      if (!entry) { writeErrno(9); return -1n; }
      const count = Number(rdx);
      const incoming = count > 0 ? new Uint8Array(engine.mem_read(Number(rsi), count)) : new Uint8Array(0);
      const cur = vfsFiles.get(entry.path) || new Uint8Array(0);
      const writePos = (entry.flags & 1024) ? cur.length : entry.pos;
      const endPos = writePos + count;
      const next = new Uint8Array(Math.max(cur.length, endPos));
      next.set(cur, 0);
      if (count > 0) next.set(incoming, writePos);
      vfsFiles.set(entry.path, next);
      entry.pos = endPos;
      return BigInt(count);
    });

    let coreModule = null;
    addShim("dlopen", () => BigInt(coreModule.base));
    addShim("dlsym", (rdi, rsi) => {
      const sym = readGuestString(Number(rsi));
      return BigInt(coreModule.exports.get(sym) || 0);
    });

    function mapSharedObject(rawBytes, baseAddr) {
      const parsed = parseSharedObject(rawBytes);
      let minVaddr = Infinity, maxVaddr = 0;
      for (const seg of parsed.segments) {
        if (seg.pVaddr < minVaddr) minVaddr = seg.pVaddr;
        if (seg.pVaddr + seg.pMemsz > maxVaddr) maxVaddr = seg.pVaddr + seg.pMemsz;
      }
      const alignedMin = alignDown(minVaddr);
      const mapBytes = alignUp(maxVaddr) - alignedMin;
      const bias = baseAddr - alignedMin;
      const image = new Uint8Array(mapBytes);
      const imageView = new DataView(image.buffer);

      for (const seg of parsed.segments) {
        image.set(rawBytes.subarray(seg.pOffset, seg.pOffset + seg.pFilesz), seg.pVaddr - alignedMin);
      }

      const exports = new Map();
      for (const sym of parsed.symbols) {
        if (sym.shndx !== 0 && sym.value !== 0 && sym.name) {
          exports.set(sym.name, bias + sym.value);
        }
      }

      for (const rel of parsed.relocations) {
        const off = rel.offset - alignedMin;
        if (rel.type === 8) {
          imageView.setBigUint64(off, BigInt(bias + rel.addend), true);
          continue;
        }
        const sym = parsed.symbols[rel.symIdx] || { name: "", shndx: 0, value: 0 };
        let target = trapStub;
        if (sym.shndx !== 0 && sym.value !== 0) target = bias + sym.value;
        else if (shimByName.has(sym.name)) target = shimByName.get(sym.name);
        if (rel.type === 7) imageView.setBigUint64(off, BigInt(target), true);
        else if (rel.type === 6 || rel.type === 1) imageView.setBigUint64(off, BigInt(target + rel.addend), true);
        else throw new Error("Unsupported relocation kind: " + rel.type);
      }

      engine.mem_map(baseAddr, mapBytes, mod.PROT_ALL);
      engine.mem_write(baseAddr, image);
      return { base: baseAddr, exports };
    }

    coreModule = mapSharedObject(coreBytes, 0x20000000);
    const serviceModule = mapSharedObject(sscBytes, 0x10000000);

    let pendingHookError = null;
    const codeHook = engine.hook_add(mod.HOOK_CODE, (_, addrLo) => {
      const addr = Number(BigInt.asUintN(64, BigInt(addrLo)));
      if (addr === trapStub) {
        pendingHookError = new Error("Store library invoked an unimplemented import");
        engine.emu_stop();
        return;
      }
      const entry = shimByAddr.get(addr);
      if (entry) {
        try {
          const rdi = BigInt.asUintN(64, engine.reg_read_i64(mod.X86_REG_RDI));
          const rsi = BigInt.asUintN(64, engine.reg_read_i64(mod.X86_REG_RSI));
          const rdx = BigInt.asUintN(64, engine.reg_read_i64(mod.X86_REG_RDX));
          const rcx = BigInt.asUintN(64, engine.reg_read_i64(mod.X86_REG_RCX));
          const r8 = BigInt.asUintN(64, engine.reg_read_i64(mod.X86_REG_R8));
          const r9 = BigInt.asUintN(64, engine.reg_read_i64(mod.X86_REG_R9));
          const rv = entry.handler(rdi, rsi, rdx, rcx, r8, r9);
          engine.reg_write_i64(mod.X86_REG_RAX, BigInt.asIntN(64, rv));
        } catch (err) {
          pendingHookError = err;
          engine.emu_stop();
        }
      }
    }, {}, shimAddr, shimAddr + shimBytes);

    function invoke(symbolName, ...args) {
      const fnAddr = serviceModule.exports.get(symbolName);
      if (!fnAddr) throw new Error("Missing Store symbol: " + symbolName);
      // System V AMD64 ABI requires (RSP + 8) % 16 === 0 upon function entry.
      const rsp = stackAddr + stackBytes - 0x1008;
      const frame = new Uint8Array(8 + Math.max(0, args.length - 6) * 8);
      const frameView = new DataView(frame.buffer);
      frameView.setBigUint64(0, BigInt(returnStub), true);
      for (let i = 6; i < args.length; i++) {
        frameView.setBigInt64(8 * (i - 5), BigInt.asIntN(64, BigInt(args[i])), true);
      }
      engine.mem_write(rsp, frame);
      engine.reg_write_i64(mod.X86_REG_RSP, BigInt(rsp));

      const argRegs = [mod.X86_REG_RDI, mod.X86_REG_RSI, mod.X86_REG_RDX, mod.X86_REG_RCX, mod.X86_REG_R8, mod.X86_REG_R9];
      for (let i = 0; i < args.length && i < 6; i++) {
        engine.reg_write_i64(argRegs[i], BigInt.asIntN(64, BigInt(args[i])));
      }
      pendingHookError = null;
      engine.emu_start(fnAddr, returnStub, 0, 0);
      if (pendingHookError) throw pendingHookError;
      return Number(BigInt.asIntN(32, engine.reg_read_i64(mod.X86_REG_RAX)));
    }

    function withGuestCString(str, fn) {
      const encoded = textEncoder.encode(str + "\0");
      const ptr = guestAlloc(encoded.length);
      try {
        engine.mem_write(ptr, encoded);
        return fn(ptr);
      } finally {
        guestFree(ptr);
      }
    }

    function allocGuestBytes(bytes) {
      if (!bytes || bytes.length === 0) return 0;
      const ptr = guestAlloc(bytes.length);
      engine.mem_write(ptr, bytes);
      return ptr;
    }

    const SYMBOLS = {
      loadLibrary: "kq56gsgHG6",
      setAndroidID: "Sph98paBcz",
      setProvisioningPath: "nf92ngaK92",
      provisioningErase: "p435tmhbla",
      provisioningDestroy: "fy34trz2st",
      provisioningEnd: "uv5t6nhkui",
      provisioningStart: "rsegvyrt87",
      getLoginCode: "aslgmuibau",
      dispose: "jk24uiwqrg",
      otpRequest: "qi864985u0"
    };

    function checkCode(rc, contextLabel) {
      if (rc !== 0) throw new Error(contextLabel + " failed (" + rc + ")");
    }

    checkCode(withGuestCString("/adi", ptr => invoke(SYMBOLS.loadLibrary, ptr)), "Store library load");
    checkCode(withGuestCString("/adi", ptr => invoke(SYMBOLS.setProvisioningPath, ptr)), "Store path setup");
    checkCode(withGuestCString(identifier, ptr => invoke(SYMBOLS.setAndroidID, ptr, identifier.length)), "Store identifier setup");

    function exportFilesObject() {
      const files = {};
      for (const [fullPath, data] of vfsFiles.entries()) {
        if (fullPath.startsWith("/adi/")) {
          const name = fullPath.slice(5);
          if (name && !name.includes("/")) files[name] = data.length === 0 ? "" : bytesToBase64(data);
        }
      }
      return files;
    }

    function filesDigest(filesMap) {
      const entries = [];
      for (const [k, v] of filesMap.entries()) {
        entries.push(k + ":" + (v.length === 0 ? "" : bytesToBase64(v)));
      }
      entries.sort();
      return entries.join("|");
    }

    return {
      identifier,
      matches(nextId, nextFiles) {
        return identifier === nextId && filesDigest(vfsFiles) === filesDigest(nextFiles);
      },
      isProvisioned() {
        const rc = invoke(SYMBOLS.getLoginCode, STORE_SCOPE);
        if (rc === 0) return true;
        if (rc === NOT_PROVISIONED_CODE) return false;
        throw new Error("Store status check failed (" + rc + ")");
      },
      requestOTP() {
        const outSlot = guestAlloc(32);
        try {
          checkCode(invoke(SYMBOLS.otpRequest, STORE_SCOPE, outSlot, outSlot + 8, outSlot + 16, outSlot + 24), "Store proof generation");
          const raw = new Uint8Array(engine.mem_read(outSlot, 32));
          const view = new DataView(raw.buffer, raw.byteOffset, 32);
          const midPtr = Number(view.getBigUint64(0, true));
          const midLen = view.getUint32(8, true);
          const otpPtr = Number(view.getBigUint64(16, true));
          const otpLen = view.getUint32(24, true);
          const mid = midPtr && midLen > 0 ? new Uint8Array(engine.mem_read(midPtr, midLen)) : new Uint8Array(0);
          const otp = otpPtr && otpLen > 0 ? new Uint8Array(engine.mem_read(otpPtr, otpLen)) : new Uint8Array(0);
          if (otpPtr) invoke(SYMBOLS.dispose, otpPtr);
          if (midPtr) invoke(SYMBOLS.dispose, midPtr);
          if (otp.length === 0 || mid.length === 0) throw new Error("Store library returned empty proof");
          return {
            "X-Apple-AMD": bytesToBase64(otp),
            "X-Apple-AMD-M": bytesToBase64(mid)
          };
        } finally {
          guestFree(outSlot);
        }
      },
      startProvisioning(spimBytes) {
        const spimPtr = allocGuestBytes(spimBytes);
        const outSlot = guestAlloc(24);
        try {
          checkCode(invoke(SYMBOLS.provisioningStart, STORE_SCOPE, spimPtr, spimBytes.length, outSlot, outSlot + 8, outSlot + 16), "Store provisioning start");
          const raw = new Uint8Array(engine.mem_read(outSlot, 24));
          const view = new DataView(raw.buffer, raw.byteOffset, 24);
          const cpimPtr = Number(view.getBigUint64(0, true));
          const cpimLen = view.getUint32(8, true);
          const session = view.getUint32(16, true);
          const cpim = cpimPtr && cpimLen > 0 ? new Uint8Array(engine.mem_read(cpimPtr, cpimLen)) : new Uint8Array(0);
          if (cpimPtr) invoke(SYMBOLS.dispose, cpimPtr);
          if (cpim.length === 0) throw new Error("Store provisioning produced empty client data");
          return { cpim, session };
        } finally {
          if (spimPtr) guestFree(spimPtr);
          guestFree(outSlot);
        }
      },
      endProvisioning(session, ptmBytes, tkBytes) {
        const ptmPtr = allocGuestBytes(ptmBytes);
        const tkPtr = allocGuestBytes(tkBytes);
        try {
          checkCode(invoke(SYMBOLS.provisioningEnd, session >>> 0, ptmPtr, ptmBytes.length, tkPtr, tkBytes.length), "Store provisioning finish");
        } finally {
          if (ptmPtr) guestFree(ptmPtr);
          if (tkPtr) guestFree(tkPtr);
        }
      },
      destroyProvisioning(session) {
        invoke(SYMBOLS.provisioningDestroy, session >>> 0);
      },
      exportState() {
        return { identifier, files: exportFilesObject() };
      },
      close() {
        try { engine.hook_del(codeHook); } catch (_) {}
        try { mod._free(frameBuf); } catch (_) {}
        try { engine.close(); } catch (_) {}
      }
    };
  }

  async function ensureStoreRuntime(identifier, files, options) {
    if (storeRuntimeInstance && storeRuntimeInstance.matches(identifier, files)) {
      return storeRuntimeInstance;
    }
    if (storeRuntimeInstance) {
      storeRuntimeInstance.close();
      storeRuntimeInstance = null;
    }
    storeRuntimeInstance = await createStoreRuntime(identifier, files, options);
    return storeRuntimeInstance;
  }

  function enqueueStoreProof(task) {
    const next = storeProofQueue.then(task);
    storeProofQueue = next.catch(() => {});
    return next;
  }

  function sapStoreProofHeaders(stateJson, options) {
    return enqueueStoreProof(async () => {
      const { identifier, files } = parseInputState(stateJson);
      const runtime = await ensureStoreRuntime(identifier, files, options || {});
      const provisioned = runtime.isProvisioned();
      if (!provisioned) {
        return JSON.stringify({ provisioned: false, state: runtime.exportState() });
      }
      const headers = runtime.requestOTP();
      return JSON.stringify({ provisioned: true, headers, state: runtime.exportState() });
    });
  }

  function sapStoreProvision(stateJson, challengeBase64, guid, options) {
    return enqueueStoreProof(async () => {
      const { identifier, files } = parseInputState(stateJson);
      if (typeof guid !== "string") throw new TypeError("guid must be a string");
      const normalizedGuid = guid.trim().replace(/:/g, "").toUpperCase();
      if (!/^[0-9A-F]{12}$/.test(normalizedGuid)) {
        throw new TypeError("Store GUID must contain 12 hexadecimal characters");
      }
      if (typeof challengeBase64 !== "string" || challengeBase64.length === 0 || challengeBase64.length > 16384) {
        throw new TypeError("Invalid Store challenge length");
      }
      const challengeBytes = strictBase64ToBytes(challengeBase64, false);
      const opts = options || {};
      let runtime;
      let started;
      try {
        runtime = await ensureStoreRuntime(identifier, files, opts);
        started = runtime.startProvisioning(challengeBytes);
      } catch (err) {
        if (files.size === 0) throw err;
        if (storeRuntimeInstance) {
          storeRuntimeInstance.close();
          storeRuntimeInstance = null;
        }
        runtime = await ensureStoreRuntime(identifier, new Map(), opts);
        started = runtime.startProvisioning(challengeBytes);
      }
      const { cpim, session } = started;
      let completed = false;
      try {
        const proxyBase = opts.proxyURL || DEFAULT_PROXY_URL;
        const bodyXml = encodeFinishPlist(bytesToBase64(cpim), normalizedGuid);
        const response = await fetch(proxyURL(proxyBase, FINISH_URL), {
          method: "POST",
          headers: { "Content-Type": "application/x-apple-plist" },
          body: textEncoder.encode(bodyXml)
        });
        if (response.status !== 200) {
          throw new Error("Store provisioning endpoint returned HTTP " + response.status);
        }
        const rawBytes = new Uint8Array(await response.arrayBuffer());
        if (rawBytes.length === 0 || rawBytes.length > 1048576) {
          throw new Error("Invalid Store provisioning response size");
        }
        const rawDict = parseXmlPlistDict(textDecoder.decode(rawBytes));
        const dict = (rawDict && typeof rawDict.Protocol === "object" && rawDict.Protocol && !Array.isArray(rawDict.Protocol))
          ? rawDict.Protocol
          : rawDict;
        if (typeof dict.settingInfo !== "string" || typeof dict.transportKey !== "string") {
          throw new Error("Store provisioning response lacks settingInfo or transportKey");
        }
        const ptmBytes = strictBase64ToBytes(dict.settingInfo, true);
        const tkBytes = strictBase64ToBytes(dict.transportKey, true);
        runtime.endProvisioning(session, ptmBytes, tkBytes);
        completed = true;
      } finally {
        if (!completed) {
          try { runtime.destroyProvisioning(session); } catch (_) {}
        }
      }
      if (!runtime.isProvisioned()) {
        throw new Error("Store runtime remained unprovisioned after finish");
      }
      const headers = runtime.requestOTP();
      return JSON.stringify({ provisioned: true, headers, state: runtime.exportState() });
    });
  }

  root.loadSapSigner = loadSapSigner;
  root.sapGenerateKBSync = sapGenerateKBSync;
  root.createSapSigner = createSapSigner;
  root.SapSigner = SapSigner;
  root.sapInitialize = sapInitialize;
  root.sapSign = sapSign;
  root.sapSignOnce = sapSignOnce;
  root.sapClose = sapClose;
  root.sapStoreProofHeaders = sapStoreProofHeaders;
  root.sapStoreProvision = sapStoreProvision;
})(typeof globalThis === "undefined" ? window : globalThis);
