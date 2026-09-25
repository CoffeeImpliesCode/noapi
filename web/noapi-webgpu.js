mergeInto(LibraryManager.library, {
  noapi_webgpu_panic: function (message, length) {
    console.error("noapi WASM panic: " + UTF8ToString(message, length));
  }
});

mergeInto(LibraryManager.library, {
  $NoapiWebGpu: {

  getState: function () {
    if (!Module["noapiWebGpu"]) throw new Error("noapi WebGPU is not initialized");
    return Module["noapiWebGpu"];
  },

  fail: function (code, error) {
    var state = Module["noapiWebGpu"];
    if (!state) return;
    if (!state.error) {
      state.error = { code: code, message: String(error || "WebGPU operation failed") };
      console.error("noapi WebGPU error " + code + ": " + state.error.message);
    }
  },

  resourceId: function (state) {
    if (state.nextId >= 0xffffffff) throw new Error("WebGPU resource handle space exhausted");
    return state.nextId++;
  },

  deferDestroy: function (state, resource) {
    if (!resource) return;
    if (state.frame) {
      state.frame.deferredDestroy.push(resource);
      return;
    }
    state.device.queue.onSubmittedWorkDone().then(function () {
      resource.destroy();
    }).catch(function (error) {
      NoapiWebGpu.fail(1, error);
      resource.destroy();
    });
  },

  finishDeferred: function (state, resources) {
    if (resources.length === 0) return;
    state.device.queue.onSubmittedWorkDone().then(function () {
      for (var i = 0; i < resources.length; i++) resources[i].destroy();
    }).catch(function (error) {
      NoapiWebGpu.fail(2, error);
      for (var i = 0; i < resources.length; i++) resources[i].destroy();
    });
  },

  buffer: function (state, id) {
    var buffer = state.buffers.get(id);
    if (!buffer) throw new Error("invalid GPUBuffer handle " + id);
    return buffer;
  },

  texture: function (state, id) {
    var texture = state.textures.get(id);
    if (!texture) throw new Error("invalid GPUTexture handle " + id);
    return texture;
  },

  frame: function (state, command) {
    var frame = state.frame;
    if (!frame || frame.command !== command) throw new Error("invalid WebGPU command buffer");
    return frame;
  },

  createPipeline: function (state, frame) {
    if (!frame.vertexShader || !frame.fragmentShader) throw new Error("graphics shaders are not bound");
    var vertexShader = state.shaders.get(frame.vertexShader);
    var fragmentShader = state.shaders.get(frame.fragmentShader);
    if (!vertexShader || !fragmentShader) throw new Error("invalid graphics shader handle");
    var key = JSON.stringify([
      frame.vertexShader,
      frame.fragmentShader,
      frame.vertexBindings,
      frame.vertexAttributes,
      frame.topology,
      frame.cullMode,
      frame.frontFace,
      frame.blendEnabled,
      state.format
    ]);
    var pipeline = state.pipelineCache.get(key);
    if (pipeline) return pipeline;

    var layouts = frame.vertexBindings.map(function (binding) {
      var attributes = frame.vertexAttributes.filter(function (attribute) {
        return attribute.binding === binding.binding;
      }).map(function (attribute) {
        var formats = {
          100: "float32",
          103: "float32x2",
          106: "float32x3",
          109: "float32x4"
        };
        var format = formats[attribute.format];
        if (!format) throw new Error("unsupported WebGPU vertex format " + attribute.format);
        return {
          shaderLocation: attribute.location,
          offset: attribute.offset,
          format: format
        };
      });
      if (attributes.length === 0) throw new Error("vertex buffer has no attributes");
      if (binding.input_rate > 1) throw new Error("unsupported vertex input rate");
      return {
        arrayStride: binding.stride,
        stepMode: binding.input_rate === 0 ? "vertex" : "instance",
        attributes: attributes
      };
    });
    for (var i = 0; i < frame.vertexAttributes.length; i++) {
      var found = frame.vertexBindings.some(function (binding) {
        return binding.binding === frame.vertexAttributes[i].binding;
      });
      if (!found) throw new Error("vertex attribute references a missing binding");
    }

    var primitive = {
      topology: frame.topology,
      frontFace: frame.frontFace,
      cullMode: frame.cullMode
    };
    var target = { format: state.format };
    if (frame.blendEnabled) {
      target.blend = {
        color: { srcFactor: "src-alpha", dstFactor: "one-minus-src-alpha", operation: "add" },
        alpha: { srcFactor: "one", dstFactor: "one-minus-src-alpha", operation: "add" }
      };
    }
    pipeline = state.device.createRenderPipeline({
      label: vertexShader.name + "/" + fragmentShader.name,
      layout: "auto",
      vertex: {
        module: vertexShader.module,
        entryPoint: vertexShader.entry,
        buffers: layouts
      },
      fragment: {
        module: fragmentShader.module,
        entryPoint: fragmentShader.entry,
        targets: [target]
      },
      primitive: primitive,
      multisample: { count: 1 }
    });
    state.pipelineCache.set(key, pipeline);
    return pipeline;
  },

  sampler: function (state, desc) {
    var key = JSON.stringify(desc);
    var sampler = state.samplers.get(key);
    if (sampler) return sampler;
    var filters = ["linear", "nearest"];
    var addressModes = ["repeat", "mirror-repeat", "clamp-to-edge"];
    if (desc.minFilter > 1 || desc.magFilter > 1 || desc.mipFilter > 1 ||
        desc.addressU > 2 || desc.addressV > 2 || desc.addressW > 2) {
      throw new Error("unsupported WebGPU sampler descriptor");
    }
    sampler = state.device.createSampler({
      minFilter: filters[desc.minFilter],
      magFilter: filters[desc.magFilter],
      mipmapFilter: filters[desc.mipFilter],
      addressModeU: addressModes[desc.addressU],
      addressModeV: addressModes[desc.addressV],
      addressModeW: addressModes[desc.addressW]
    });
    state.samplers.set(key, sampler);
    return sampler;
  },

  draw: function (state, frame, indexed, args) {
    if (!frame.pass) throw new Error("draw called outside a rendering pass");
    var pipeline = NoapiWebGpu.createPipeline(state, frame);
    frame.pass.setPipeline(pipeline);
    for (var entry of frame.vertexBuffers.entries()) {
      frame.pass.setVertexBuffer(entry[0], entry[1].buffer, entry[1].offset);
    }

    if (frame.vertexData) {
      var vertexData = frame.vertexData;
      var vertexBuffer = NoapiWebGpu.buffer(state, vertexData.bufferId);
      if (vertexData.byteOffset % 4 !== 0 || vertexData.byteOffset >= vertexBuffer.size) {
        throw new Error("vertex data offset exceeds its GPUBuffer allocation or alignment");
      }
      if (vertexBuffer.allocationSize > state.device.limits.maxStorageBufferBindingSize) {
        throw new Error("vertex data buffer exceeds maxStorageBufferBindingSize");
      }
      var vertexOffsetUniform = state.device.createBuffer({
        label: "noapi vertex data offset",
        size: 16,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
      });
      frame.uniforms.push(vertexOffsetUniform);
      state.device.queue.writeBuffer(
        vertexOffsetUniform,
        0,
        new Uint32Array([vertexData.byteOffset, 0, 0, 0])
      );
      var vertexDataBindGroup = state.device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
          {
            binding: 0,
            resource: {
              buffer: vertexBuffer.buffer,
              offset: 0,
              size: vertexBuffer.allocationSize
            }
          },
          { binding: 1, resource: { buffer: vertexOffsetUniform, offset: 0, size: 16 } }
        ]
      });
      frame.pass.setBindGroup(0, vertexDataBindGroup);
    } else if (frame.textures.size !== 0) {
      var textureA = frame.textures.get(0);
      var textureB = frame.textures.get(1);
      if (!textureA || !textureB) throw new Error("texture shader requires texture slots 0 and 1");
      if (JSON.stringify(textureA.sampler) !== JSON.stringify(textureB.sampler)) {
        throw new Error("texture shader requires one shared sampler");
      }
      var sampler = NoapiWebGpu.sampler(state, textureA.sampler);
      var uniform = state.device.createBuffer({
        label: "noapi draw fade",
        size: 16,
        usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
      });
      frame.uniforms.push(uniform);
      state.device.queue.writeBuffer(uniform, 0, new Float32Array([frame.fade, 0, 0, 0]));
      var bindGroup = state.device.createBindGroup({
        layout: pipeline.getBindGroupLayout(0),
        entries: [
          { binding: 0, resource: NoapiWebGpu.texture(state, textureA.texture).createView() },
          { binding: 1, resource: NoapiWebGpu.texture(state, textureB.texture).createView() },
          { binding: 2, resource: sampler },
          { binding: 3, resource: { buffer: uniform, offset: 0, size: 16 } }
        ]
      });
      frame.pass.setBindGroup(0, bindGroup);
    }

    if (indexed) {
      if (!frame.indexBuffer) throw new Error("indexed draw has no index buffer");
      frame.pass.setIndexBuffer(frame.indexBuffer.buffer, frame.indexBuffer.format, frame.indexBuffer.offset);
      frame.pass.drawIndexed(args.indexCount, args.instanceCount, args.firstIndex, args.vertexOffset, 0);
    } else {
      frame.pass.draw(args.vertexCount, args.instanceCount, 0, 0);
    }
  }
  },

  noapi_webgpu_init__deps: ['$NoapiWebGpu'],
  noapi_webgpu_init: function (framesInFlight) {
    try {
      var device = Module["noapiDevice"];
      var context = Module["noapiContext"];
      if (!device || !context || !navigator.gpu) throw new Error("WebGPU device and canvas context are required before WASM starts");
      var state = {
        device: device,
        context: context,
        canvas: null,
        format: navigator.gpu.getPreferredCanvasFormat(),
        framesInFlight: framesInFlight,
        nextId: 1,
        buffers: new Map(),
        textures: new Map(),
        shaders: new Map(),
        samplers: new Map(),
        pipelineCache: new Map(),
        frame: null,
        error: null
      };
      Module["noapiWebGpu"] = state;
      device.addEventListener("uncapturederror", function (event) {
        NoapiWebGpu.fail(3, event.error && event.error.message ? event.error.message : event.error);
      });
      device.lost.then(function (info) {
        NoapiWebGpu.fail(4, info.message || "WebGPU device was lost");
      });
      return 1;
    } catch (error) {
      if (!Module["noapiWebGpu"]) Module["noapiWebGpu"] = { error: null };
      NoapiWebGpu.fail(5, error);
      return 0;
    }
  },

  noapi_webgpu_surface_init__deps: ['$NoapiWebGpu'],
  noapi_webgpu_surface_init: function (selector, selectorLen, width, height) {
    var state = Module["noapiWebGpu"];
    try {
      if (!state || !state.device || !state.context) throw new Error("WebGPU device is not initialized");
      var cssSelector = UTF8ToString(selector, selectorLen);
      var canvas = document.querySelector(cssSelector);
      if (!canvas || canvas !== state.context.canvas) throw new Error("canvas selector does not match the WebGPU context");
      if (width === 0 || height === 0) throw new Error("canvas extent must be non-zero");
      canvas.width = width;
      canvas.height = height;
      state.context.configure({
        device: state.device,
        format: state.format,
        alphaMode: "opaque"
      });
      state.canvas = canvas;
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(6, error);
      return 0;
    }
  },

  noapi_webgpu_surface_resize__deps: ['$NoapiWebGpu'],
  noapi_webgpu_surface_resize: function (width, height) {
    var state = Module["noapiWebGpu"];
    try {
      if (!state || !state.canvas || width === 0 || height === 0) throw new Error("invalid canvas resize");
      state.canvas.width = width;
      state.canvas.height = height;
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(7, error);
      return 0;
    }
  },

  noapi_webgpu_begin_frame__deps: ['$NoapiWebGpu'],
  noapi_webgpu_begin_frame: function () {
    try {
      var state = NoapiWebGpu.getState();
      if (state.error) return 0;
      if (state.frame) throw new Error("previous frame was not submitted");
      if (!state.canvas) throw new Error("WebGPU surface is not initialized");
      var currentTexture = state.context.getCurrentTexture();
      state.frame = {
        command: NoapiWebGpu.resourceId(state),
        encoder: state.device.createCommandEncoder({ label: "noapi frame" }),
        surfaceView: currentTexture.createView(),
        currentTexture: currentTexture,
        pass: null,
        vertexShader: 0,
        fragmentShader: 0,
        vertexBindings: [],
        vertexAttributes: [],
        vertexBuffers: new Map(),
        indexBuffer: null,
        topology: "triangle-list",
        cullMode: "none",
        frontFace: "ccw",
        blendEnabled: false,
        textures: new Map(),
        vertexData: null,
        fade: 0,
        uniforms: [],
        deferredDestroy: []
      };
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(8, error);
      return 0;
    }
  },

  noapi_webgpu_commands_begin__deps: ['$NoapiWebGpu'],
  noapi_webgpu_commands_begin: function () {
    try {
      var state = NoapiWebGpu.getState();
      if (!state.frame) throw new Error("commandsBegin called outside a frame");
      return state.frame.command;
    } catch (error) {
      NoapiWebGpu.fail(9, error);
      return 0;
    }
  },

  noapi_webgpu_commands_current__deps: ['$NoapiWebGpu'],
  noapi_webgpu_commands_current: function () {
    var state = Module["noapiWebGpu"];
    return state && state.frame ? state.frame.command : 0;
  },

  noapi_webgpu_end_frame__deps: ['$NoapiWebGpu'],
  noapi_webgpu_end_frame: function (command) {
    var state = Module["noapiWebGpu"];
    try {
      var frame = NoapiWebGpu.frame(state, command);
      if (frame.pass) throw new Error("rendering pass was not ended");
      if (state.error) {
        state.frame = null;
        frame.deferredDestroy.push.apply(frame.deferredDestroy, frame.uniforms);
        NoapiWebGpu.finishDeferred(state, frame.deferredDestroy);
        return 0;
      }
      var commandBuffer = frame.encoder.finish({ label: "noapi frame commands" });
      state.device.queue.submit([commandBuffer]);
      state.frame = null;
      frame.deferredDestroy.push.apply(frame.deferredDestroy, frame.uniforms);
      NoapiWebGpu.finishDeferred(state, frame.deferredDestroy);
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(10, error);
      if (state && state.frame && state.frame.command === command) {
        var abandoned = state.frame;
        state.frame = null;
        NoapiWebGpu.finishDeferred(state, abandoned.deferredDestroy.concat(abandoned.uniforms));
      }
      return 0;
    }
  },
  noapi_webgpu_abort_frame__deps: ['$NoapiWebGpu'],
  noapi_webgpu_abort_frame: function (command) {
    var state = Module["noapiWebGpu"];
    try {
      var frame = NoapiWebGpu.frame(state, command);
      state.frame = null;
      frame.deferredDestroy.push.apply(frame.deferredDestroy, frame.uniforms);
      NoapiWebGpu.finishDeferred(state, frame.deferredDestroy);
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(82, error);
      return 0;
    }
  },


  noapi_webgpu_take_error__deps: ['$NoapiWebGpu'],
  noapi_webgpu_take_error: function () {
    var state = Module["noapiWebGpu"];
    if (!state || !state.error) return 0;
    state.error = null;
    return 1;
  },


  noapi_webgpu_fail__deps: ['$NoapiWebGpu'],
  noapi_webgpu_fail: function (code) {
    NoapiWebGpu.fail(code, "unsupported operation or failed bridge call");
  },

  noapi_webgpu_get_limit__deps: ['$NoapiWebGpu'],
  noapi_webgpu_get_limit: function (key) {
    try {
      var limits = NoapiWebGpu.getState().device.limits;
      var names = [
        "maxTextureDimension2D",
        "maxTextureDimension3D",
        "maxTextureArrayLayers",
        "maxColorAttachments",
        "maxComputeInvocationsPerWorkgroup",
        "maxComputeWorkgroupStorageSize"
      ];
      return limits[names[key]] || 0;
    } catch (error) {
      NoapiWebGpu.fail(11, error);
      return 0;
    }
  },

  noapi_webgpu_shader_create__deps: ['$NoapiWebGpu'],
  noapi_webgpu_shader_create: function (source, sourceLen, stage, entry, name) {
    try {
      var state = NoapiWebGpu.getState();
      var text = UTF8ToString(source, sourceLen);
      var entryName = UTF8ToString(entry);
      var shaderName = UTF8ToString(name);
      var module = state.device.createShaderModule({ label: shaderName, code: text });
      var id = NoapiWebGpu.resourceId(state);
      state.shaders.set(id, {
        module: module,
        stage: stage,
        entry: entryName,
        name: shaderName
      });
      module.getCompilationInfo().then(function (info) {
        for (var i = 0; i < info.messages.length; i++) {
          if (info.messages[i].type === "error") {
            NoapiWebGpu.fail(12, shaderName + ": " + info.messages[i].message);
            break;
          }
        }
      }).catch(function (error) {
        NoapiWebGpu.fail(13, error);
      });
      return id;
    } catch (error) {
      NoapiWebGpu.fail(14, error);
      return 0;
    }
  },

  noapi_webgpu_shader_destroy__deps: ['$NoapiWebGpu'],
  noapi_webgpu_shader_destroy: function (shader) {
    var state = Module["noapiWebGpu"];
    if (state) state.shaders.delete(shader);
  },

  noapi_webgpu_set_shaders__deps: ['$NoapiWebGpu'],
  noapi_webgpu_set_shaders: function (command, vertex, fragment) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      var state = NoapiWebGpu.getState();
      var vertexShader = state.shaders.get(vertex);
      var fragmentShader = state.shaders.get(fragment);
      if (!vertexShader || !fragmentShader || vertexShader.stage !== 0 || fragmentShader.stage !== 1) {
        throw new Error("invalid vertex or fragment shader module");
      }
      frame.vertexShader = vertex;
      frame.fragmentShader = fragment;
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(15, error);
      return 0;
    }
  },

  noapi_webgpu_buffer_create__deps: ['$NoapiWebGpu'],
  noapi_webgpu_buffer_create: function (size) {
    try {
      var state = NoapiWebGpu.getState();
      if (size === 0) throw new Error("GPUBuffer size must be non-zero");
      var allocationSize = Math.ceil(size / 4) * 4;
      var id = NoapiWebGpu.resourceId(state);
      var buffer = state.device.createBuffer({
        label: "noapi buffer",
        size: allocationSize,
        usage: GPUBufferUsage.COPY_SRC | GPUBufferUsage.COPY_DST | GPUBufferUsage.VERTEX |
          GPUBufferUsage.INDEX | GPUBufferUsage.UNIFORM | GPUBufferUsage.STORAGE |
          GPUBufferUsage.INDIRECT
      });
      state.buffers.set(id, { buffer: buffer, size: size, allocationSize: allocationSize });
      return id;
    } catch (error) {
      NoapiWebGpu.fail(16, error);
      return 0;
    }
  },

  noapi_webgpu_buffer_destroy__deps: ['$NoapiWebGpu'],
  noapi_webgpu_buffer_destroy: function (id) {
    var state = Module["noapiWebGpu"];
    if (!state) return;
    var record = state.buffers.get(id);
    if (!record) return;
    state.buffers.delete(id);
    NoapiWebGpu.deferDestroy(state, record.buffer);
  },

  noapi_webgpu_buffer_write__deps: ['$NoapiWebGpu'],
  noapi_webgpu_buffer_write: function (id, source, size) {
    try {
      var state = NoapiWebGpu.getState();
      var record = state.buffers.get(id);
      if (!record || size > record.size || source + size > HEAPU8.length) throw new Error("invalid GPUBuffer upload range");
      var dataSize = Math.ceil(size / 4) * 4;
      var data;
      if (dataSize === size) {
        data = HEAPU8.subarray(source, source + size);
      } else {
        data = new Uint8Array(dataSize);
        data.set(HEAPU8.subarray(source, source + size));
      }
      state.device.queue.writeBuffer(record.buffer, 0, data);
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(17, error);
      return 0;
    }
  },

  noapi_webgpu_texture_create__deps: ['$NoapiWebGpu'],
  noapi_webgpu_texture_create: function (width, height, depth, mipCount, layerCount, formatId, usageBits) {
    try {
      var state = NoapiWebGpu.getState();
      var formats = { 3: "rgba8unorm" };
      var format = formats[formatId];
      if (!format) throw new Error("unsupported WebGPU texture format " + formatId);
      var usage = GPUTextureUsage.COPY_DST;
      if (usageBits & 1) usage |= GPUTextureUsage.TEXTURE_BINDING;
      if (usageBits & 2) usage |= GPUTextureUsage.STORAGE_BINDING;
      if (usageBits & 4) usage |= GPUTextureUsage.COPY_SRC;
      if (usageBits & 8) usage |= GPUTextureUsage.RENDER_ATTACHMENT;
      if (usageBits & 16) usage |= GPUTextureUsage.RENDER_ATTACHMENT;
      var texture = state.device.createTexture({
        label: "noapi texture",
        size: { width: width, height: height, depthOrArrayLayers: Math.max(depth, layerCount) },
        mipLevelCount: mipCount,
        sampleCount: 1,
        dimension: "2d",
        format: format,
        usage: usage
      });
      var id = NoapiWebGpu.resourceId(state);
      state.textures.set(id, texture);
      return id;
    } catch (error) {
      NoapiWebGpu.fail(18, error);
      return 0;
    }
  },

  noapi_webgpu_texture_destroy__deps: ['$NoapiWebGpu'],
  noapi_webgpu_texture_destroy: function (id) {
    var state = Module["noapiWebGpu"];
    if (!state) return;
    var texture = state.textures.get(id);
    if (!texture) return;
    state.textures.delete(id);
    NoapiWebGpu.deferDestroy(state, texture);
  },

  noapi_webgpu_copy_to_texture__deps: ['$NoapiWebGpu'],
  noapi_webgpu_copy_to_texture: function (command, textureId, source, sourceLen, x, y, z, width, height, depth, mipLevel, baseLayer, layerCount) {
    try {
      var state = NoapiWebGpu.getState();
      var frame = NoapiWebGpu.frame(state, command);
      var texture = NoapiWebGpu.texture(state, textureId);
      if (frame.pass) throw new Error("texture upload inside a rendering pass is unsupported");
      if (x < 0 || y < 0 || z < 0 || source + sourceLen > HEAPU8.length) throw new Error("invalid texture upload range");
      if (mipLevel !== 0 || baseLayer !== 0 || layerCount !== 1 || depth !== 1) {
        throw new Error("only a single 2D texture upload is supported");
      }
      if (sourceLen !== width * height * 4) throw new Error("RGBA8 texture upload size does not match its extent");
      state.device.queue.writeTexture(
        { texture: texture, mipLevel: mipLevel, origin: { x: x, y: y, z: z } },
        HEAPU8.subarray(source, source + sourceLen),
        { offset: 0, bytesPerRow: width * 4, rowsPerImage: height },
        { width: width, height: height, depthOrArrayLayers: depth }
      );
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(19, error);
      return 0;
    }
  },

  noapi_webgpu_begin_rendering__deps: ['$NoapiWebGpu'],
  noapi_webgpu_begin_rendering: function (command, isSwapchain, textureId, loadOp, storeOp, clearR, clearG, clearB, clearA, offsetX, offsetY, width, height) {
    try {
      var state = NoapiWebGpu.getState();
      var frame = NoapiWebGpu.frame(state, command);
      if (frame.pass) throw new Error("nested rendering passes are unsupported");
      var view = isSwapchain ? frame.surfaceView : NoapiWebGpu.texture(state, textureId).createView();
      var renderWidth = width || state.canvas.width;
      var renderHeight = height || state.canvas.height;
      if (offsetX < 0 || offsetY < 0 || renderWidth === 0 || renderHeight === 0) throw new Error("invalid render area");
      frame.pass = frame.encoder.beginRenderPass({
        label: "noapi render pass",
        colorAttachments: [{
          view: view,
          loadOp: loadOp === 0 ? "load" : "clear",
          storeOp: storeOp === 1 ? "discard" : "store",
          clearValue: { r: clearR, g: clearG, b: clearB, a: clearA }
        }]
      });
      frame.pass.setViewport(offsetX, offsetY, renderWidth, renderHeight, 0, 1);
      frame.pass.setScissorRect(offsetX, offsetY, renderWidth, renderHeight);
      frame.renderWidth = renderWidth;
      frame.renderHeight = renderHeight;
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(20, error);
      return 0;
    }
  },

  noapi_webgpu_end_rendering__deps: ['$NoapiWebGpu'],
  noapi_webgpu_end_rendering: function (command) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      if (!frame.pass) throw new Error("endRendering called without a render pass");
      frame.pass.end();
      frame.pass = null;
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(21, error);
      return 0;
    }
  },

  noapi_webgpu_push_graphics__deps: ['$NoapiWebGpu'],
  noapi_webgpu_push_graphics: function (command, bufferId, byteOffset, fade) {
    try {
      var state = NoapiWebGpu.getState();
      var frame = NoapiWebGpu.frame(state, command);
      if (bufferId !== 0) {
        var buffer = NoapiWebGpu.buffer(state, bufferId);
        if (byteOffset % 4 !== 0 || byteOffset >= buffer.size) {
          throw new Error("vertex data offset exceeds its GPUBuffer allocation or alignment");
        }
      } else if (byteOffset !== 0) {
        throw new Error("vertex data offset has no GPUBuffer handle");
      }
      frame.vertexData = bufferId === 0 ? null : { bufferId: bufferId, byteOffset: byteOffset };
      frame.fade = fade;
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(22, error);
      return 0;
    }
  },

  noapi_webgpu_set_raster__deps: ['$NoapiWebGpu'],
  noapi_webgpu_set_raster: function (command, topology, cullMode, frontFace) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      var topologies = {
        0: "point-list",
        1: "line-list",
        2: "line-strip",
        3: "triangle-list",
        4: "triangle-strip"
      };
      var cullModes = { 0: "none", 1: "front", 2: "back" };
      if (!topologies[topology] || !cullModes[cullMode] || frontFace > 1) throw new Error("unsupported WebGPU raster state");
      frame.topology = topologies[topology];
      frame.cullMode = cullModes[cullMode];
      frame.frontFace = frontFace === 0 ? "ccw" : "cw";
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(23, error);
      return 0;
    }
  },

  noapi_webgpu_set_vertex_input__deps: ['$NoapiWebGpu'],
  noapi_webgpu_set_vertex_input: function (command, bindingsPtr, bindingCount, attributesPtr, attributeCount) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      if (bindingCount > 8 || attributeCount > 16) throw new Error("too many WebGPU vertex inputs");
      var bindings = [];
      var attributes = [];
      var words = HEAPU32;
      for (var i = 0; i < bindingCount; i++) {
        var base = (bindingsPtr >> 2) + i * 3;
        bindings.push({ binding: words[base], stride: words[base + 1], input_rate: words[base + 2] });
      }
      for (var j = 0; j < attributeCount; j++) {
        var attributeBase = (attributesPtr >> 2) + j * 4;
        attributes.push({
          location: words[attributeBase],
          binding: words[attributeBase + 1],
          format: words[attributeBase + 2],
          offset: words[attributeBase + 3]
        });
      }
      frame.vertexBindings = bindings;
      frame.vertexAttributes = attributes;
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(24, error);
      return 0;
    }
  },

  noapi_webgpu_bind_vertex_buffer__deps: ['$NoapiWebGpu'],
  noapi_webgpu_bind_vertex_buffer: function (command, binding, bufferId, offset) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      var buffer = NoapiWebGpu.buffer(NoapiWebGpu.getState(), bufferId);
      if (offset > buffer.size) throw new Error("vertex buffer offset exceeds its allocation");
      frame.vertexBuffers.set(binding, { buffer: buffer.buffer, offset: offset });
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(25, error);
      return 0;
    }
  },

  noapi_webgpu_bind_index_buffer__deps: ['$NoapiWebGpu'],
  noapi_webgpu_bind_index_buffer: function (command, bufferId, offset, format) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      var buffer = NoapiWebGpu.buffer(NoapiWebGpu.getState(), bufferId);
      var formats = { 0: "uint16", 1: "uint32" };
      if (!formats[format] || offset > buffer.size) throw new Error("unsupported index buffer format or offset");
      frame.indexBuffer = { buffer: buffer.buffer, offset: offset, format: formats[format] };
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(26, error);
      return 0;
    }
  },

  noapi_webgpu_bind_texture__deps: ['$NoapiWebGpu'],
  noapi_webgpu_bind_texture: function (command, slot, textureId, minFilter, magFilter, mipFilter, addressU, addressV, addressW) {
    try {
      var state = NoapiWebGpu.getState();
      var frame = NoapiWebGpu.frame(state, command);
      if (slot > 1) throw new Error("texture slots above 1 are unsupported");
      NoapiWebGpu.texture(state, textureId);
      frame.textures.set(slot, {
        texture: textureId,
        sampler: {
          minFilter: minFilter,
          magFilter: magFilter,
          mipFilter: mipFilter,
          addressU: addressU,
          addressV: addressV,
          addressW: addressW
        }
      });
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(27, error);
      return 0;
    }
  },

  noapi_webgpu_set_viewport__deps: ['$NoapiWebGpu'],
  noapi_webgpu_set_viewport: function (command, x, y, width, height, depthMin, depthMax) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      if (!frame.pass || width <= 0 || height <= 0) throw new Error("invalid viewport state");
      frame.pass.setViewport(x, y, width, height, depthMin, depthMax);
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(28, error);
      return 0;
    }
  },

  noapi_webgpu_set_scissor__deps: ['$NoapiWebGpu'],
  noapi_webgpu_set_scissor: function (command, x, y, width, height) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      if (!frame.pass || x < 0 || y < 0) throw new Error("invalid scissor state");
      frame.pass.setScissorRect(x, y, width, height);
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(29, error);
      return 0;
    }
  },

  noapi_webgpu_set_blend__deps: ['$NoapiWebGpu'],
  noapi_webgpu_set_blend: function (command, enabled) {
    try {
      var frame = NoapiWebGpu.frame(NoapiWebGpu.getState(), command);
      frame.blendEnabled = enabled !== 0;
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(30, error);
      return 0;
    }
  },

  noapi_webgpu_draw__deps: ['$NoapiWebGpu'],
  noapi_webgpu_draw: function (command, vertexCount, instanceCount) {
    try {
      var state = NoapiWebGpu.getState();
      var frame = NoapiWebGpu.frame(state, command);
      NoapiWebGpu.draw(state, frame, false, { vertexCount: vertexCount, instanceCount: instanceCount });
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(31, error);
      return 0;
    }
  },

  noapi_webgpu_draw_indexed__deps: ['$NoapiWebGpu'],
  noapi_webgpu_draw_indexed: function (command, indexCount, instanceCount, firstIndex, vertexOffset) {
    try {
      var state = NoapiWebGpu.getState();
      var frame = NoapiWebGpu.frame(state, command);
      NoapiWebGpu.draw(state, frame, true, {
        indexCount: indexCount,
        instanceCount: instanceCount,
        firstIndex: firstIndex,
        vertexOffset: vertexOffset
      });
      return 1;
    } catch (error) {
      NoapiWebGpu.fail(32, error);
      return 0;
    }
  }
});
