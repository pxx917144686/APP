(function (root) {
  "use strict";

  const CERTIFICATE_URL = "https://s.mzstatic.com/sap/setupCert.plist";
  const SETUP_URL = "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy";
  const DEFAULT_PROXY_URL = "http://xiaobai.com/";
  const directoryURL = value => {
    const slash = value.lastIndexOf("/");
    return slash < 0 ? "./" : value.slice(0, slash + 1);
  };
  const SCRIPT_BASE_URL = (() => {
    const script = typeof document === "undefined" ? null : document.currentScript;
    const base = script && script.src
      ? script.src
      : (typeof document === "undefined" ? "./" : document.baseURI);
    return directoryURL(base);
  })();
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
      const unicornURL = options.unicornURL || SCRIPT_BASE_URL + "unicorn_x86.js";
      const wasmExecURL = options.wasmExecURL || SCRIPT_BASE_URL + "wasm_exec.js";
      const wasmURL = options.wasmURL || SCRIPT_BASE_URL + "sap.wasm";

      if (typeof root.MUnicorn !== "function") await loadScript(unicornURL);
      if (typeof root.MUnicorn !== "function") throw new Error("Unicorn.js factory is unavailable");
      root.unicornModule = await root.MUnicorn();
      if (!root.unicornModule) throw new Error("Unicorn.js initialization failed");

      installShimBridge();
      if (typeof root.Go !== "function") await loadScript(wasmExecURL);
      if (typeof root.Go !== "function") throw new Error("Go WASM runtime is unavailable");

      const response = await fetch(wasmURL, { cache: "no-store" });
      if (!response.ok) throw new Error("load SAP WASM failed: " + response.status);
      const bytes = await response.arrayBuffer();
      const go = new root.Go();
      const compiled = await WebAssembly.instantiate(bytes, go.importObject);
      go.run(compiled.instance);

      const deadline = Date.now() + 30000;
      while (!root.sapWasmSignerReady) {
        if (Date.now() >= deadline) throw new Error("SAP WASM initialization timed out");
        await new Promise(resolve => setTimeout(resolve, 10));
      }

      const required = [
        "sapWasmPrepareSetup",
        "sapWasmFinishSetup",
        "sapWasmSign",
        "sapWasmClose",
      ];
      const missing = required.filter(name => typeof root[name] !== "function");
      if (missing.length) {
        throw new Error("SAP WASM runtime version mismatch, missing: " + missing.join(", "));
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
    const hashIndex = proxyBase.indexOf("#");
    const withoutHash = hashIndex < 0 ? proxyBase : proxyBase.slice(0, hashIndex);
    const queryIndex = withoutHash.indexOf("?");
    const base = queryIndex < 0 ? withoutHash : withoutHash.slice(0, queryIndex);
    return `${base}?url=${encodeURIComponent(upstream)}`;
  }

  async function proxyResponseBase64(response, label, options) {
    if (!response.ok) {
      // 透出代理/上游的真实失败原因（超时、被拦截、上游错误正文等）
      let detail = "";
      try {
        const text = await response.text();
        detail = text ? ": " + text.slice(0, 200) : "";
      } catch (_e) {}
      throw new Error(label + " failed: " + response.status + detail);
    }
    if (options && options.proxyEncoding === "base64-json") {
      const envelope = await response.json();
      if (!envelope || envelope.ok !== true || typeof envelope.base64 !== "string") {
        throw new Error((envelope && envelope.message) || label + " returned invalid proxy data");
      }
      return envelope.base64;
    }
    return bytesToBase64(new Uint8Array(await response.arrayBuffer()));
  }

  async function requestCertificate(proxyBase, options) {
    const response = await fetch(proxyURL(proxyBase, CERTIFICATE_URL), { cache: "no-store" });
    return proxyResponseBase64(response, "fetch SAP setup certificate", options);
  }

  async function exchangeSetup(proxyBase, requestBase64, options) {
    const response = await fetch(proxyURL(proxyBase, SETUP_URL), {
      method: "POST",
      headers: { "Content-Type": "application/x-plist" },
      body: base64ToBytes(requestBase64)
    });
    return proxyResponseBase64(response, "SAP setup request", options);
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
          const certificate = await requestCertificate(proxyBase, this.options);
          const preparation = JSON.parse(root.sapWasmPrepareSetup(this.guid, certificate));
          if (preparation.error) throw new Error(preparation.error);

          const reply = await exchangeSetup(proxyBase, preparation.requestBase64, this.options);
          const completion = JSON.parse(root.sapWasmFinishSetup(reply));
          if (completion.error) throw new Error(completion.error);
          if (completion.ready !== true) throw new Error("SAP signer setup did not complete");

          this.initialized = true;
          return true;
        } catch (error) {
          if (typeof root.sapWasmClose === "function") {
            try { root.sapWasmClose(); } catch (_closeError) {}
          }
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

  function sapClose() {
    if (!currentSigner) return Promise.resolve(false);
    const signer = currentSigner;
    currentSigner = null;
    return signer.close();
  }

  root.createSapSigner = createSapSigner;
  root.SapSigner = SapSigner;
  root.sapInitialize = sapInitialize;
  root.sapSign = sapSign;
  root.sapClose = sapClose;
})(typeof globalThis === "undefined" ? window : globalThis);
