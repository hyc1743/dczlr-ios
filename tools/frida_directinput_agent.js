'use strict';

/*
 * Local, bounded runtime probe for the supplied PE32 title.
 * The agent observes DirectInput and PP reads, and can synthesize short
 * keyboard/mouse pulses entirely in the returned GetDeviceState buffers.
 * It never patches the executable or writes to the target's code pages.
 */

const presses = __PRESSES__;
const forceMenu = __FORCE_MENU__;
const forceGameMenuInput = __FORCE_GAME_MENU__;
const forceGameReleaseInput = __FORCE_GAME_RELEASE__;
const forceGameMenuQueue = Array.isArray(forceGameMenuInput) ? forceGameMenuInput.slice() : (forceGameMenuInput ? [forceGameMenuInput] : []);
const forceGameReleaseQueue = Array.isArray(forceGameReleaseInput) ? forceGameReleaseInput.slice() : (forceGameReleaseInput ? [forceGameReleaseInput] : []);
const forceChapter = __FORCE_CHAPTER__;
const forceActions = __FORCE_ACTIONS__;
const forceDispatch = __FORCE_DISPATCH__;
const startedAt = Date.now();
const seen = {};
const hookedFunctions = {};
const handlePaths = {};
const deviceIndexes = {};
let directInputHooked = false;
let readHooksInstalled = false;
let gameHooksInstalled = false;
let eventCount = 0;
let moduleSnapshotSent = false;
let gameKeyCallCount = 0;
let cursorHooksInstalled = false;
let inputArraySnapshot = '';
let menuGeometrySent = false;
let gameplayMenuGeometrySent = false;
let forceMenuRemaining = forceMenu ? (forceMenu.frames || 5) : 0;
let forceGameMenu = null;
let forceGameRelease = null;
let forceGameMenuRemaining = 0;
let forceGameReleaseRemaining = 0;
let introStateSnapshot = '';
let dispatcherSnapshot = '';
let forceChapterApplied = false;
let forceActionsRemaining = forceActions ? (forceActions.frames || 3) : 0;
let forceDispatchRemaining = forceDispatch ? (forceDispatch.frames || 3) : 0;
let gameplayStateSnapshot = '';
let audioDispatcherSnapshot = '';
const gameplayCallbackCounts = {};

function elapsed() {
  return Math.round((Date.now() - startedAt) / 1000 * 1000) / 1000;
}

function emit(kind, fields) {
  const event = Object.assign({time: elapsed(), kind: kind}, fields || {});
  eventCount += 1;
  send(event);
}

function safeString(value) {
  try { return value ? String(value) : ''; } catch (_) { return ''; }
}

function pointerKey(value) {
  try { return value.toString(); } catch (_) { return '0x0'; }
}

function validPointer(value) {
  try { return value && !value.isNull(); } catch (_) { return false; }
}

function safeReadU32(value) {
  try { return value.readU32(); } catch (_) { return 0; }
}

function safeArgU32(value) {
  try { return value.toUInt32(); } catch (_) { return 0; }
}

function bitsToFloat(value) {
  try {
    const buffer = new ArrayBuffer(4);
    const view = new DataView(buffer);
    view.setUint32(0, value >>> 0, true);
    return view.getFloat32(0, true);
  } catch (_) { return 0; }
}

function safeArgFloat(value) {
  return bitsToFloat(safeArgU32(value));
}

function safeArgS32(value) {
  try { return value.toInt32(); } catch (_) { return 0; }
}

function safeReadUtf16(value) {
  try { return value.readUtf16String(); } catch (_) { return ''; }
}

function safeReadAnsi(value) {
  try { return value.readAnsiString(); } catch (_) { return ''; }
}

function installOnce(address, key, callbacks) {
  const id = key + ':' + pointerKey(address);
  if (hookedFunctions[id]) return false;
  hookedFunctions[id] = true;
  Interceptor.attach(address, callbacks);
  return true;
}

function moduleExport(name) {
  const candidates = ['dinput8.dll', 'kernel32.dll', 'kernelbase.dll', 'user32.dll'];
  for (const moduleName of candidates) {
    try {
      const found = Module.findExportByName(moduleName, name);
      if (found) return found;
    } catch (_) {}
    try {
      const found = Module.getExportByName(moduleName, name);
      if (found) return found;
    } catch (_) {}
  }
  try {
    const found = Module.findGlobalExportByName(name);
    if (found) return found;
  } catch (_) {}
  return null;
}

function readBytes(ptr, length) {
  const result = [];
  if (!validPointer(ptr) || length <= 0) return result;
  try {
    for (let i = 0; i < length; ++i) {
      const value = ptr.add(i).readU8();
      if (value !== 0) result.push([i, value]);
    }
  } catch (_) {}
  return result;
}

function activePresses(now, kind) {
  return presses.filter(function (press) {
    return press.kind === kind && now >= press.at && now < press.at + press.duration;
  });
}

function hookGetDeviceState(device, deviceIndex) {
  if (!validPointer(device)) return;
  deviceIndexes[pointerKey(device)] = deviceIndex;
  let vtable;
  try { vtable = device.readPointer(); } catch (_) { return; }
  if (!validPointer(vtable)) return;
  const method = vtable.add(Process.pointerSize * 9).readPointer();
  if (!validPointer(method)) return;
  installOnce(method, 'GetDeviceState', {
    onEnter: function (args) {
      this.deviceIndex = deviceIndexes[pointerKey(args[0])];
      if (this.deviceIndex === undefined) this.deviceIndex = deviceIndex;
      this.cbData = safeArgU32(args[1]);
      this.data = args[2];
    },
    onLeave: function (retval) {
      if (retval.toInt32() !== 0 || !validPointer(this.data)) return;
      const now = elapsed();
      const before = readBytes(this.data, Math.min(this.cbData, 256));
      const injected = [];
      if (this.cbData === 256) {
        activePresses(now, 'keyboard').forEach(function (press) {
          try {
            const code = press.code >>> 0;
            if (code < 256) {
              this.data.add(code).writeU8(0x80);
              injected.push({code: code, value: 0x80, label: press.label || ''});
            }
          } catch (_) {}
        }, this);
      } else if (this.cbData === 16) {
        activePresses(now, 'mouse').forEach(function (press) {
          try {
            const dx = (press.dx || 0) | 0;
            const dy = (press.dy || 0) | 0;
            const button = press.button === undefined ? 0 : press.button | 0;
            this.data.writeS32(dx);
            this.data.add(4).writeS32(dy);
            if (button >= 0 && button < 4) this.data.add(12 + button).writeU8(0x80);
            injected.push({button: button, dx: dx, dy: dy, label: press.label || ''});
          } catch (_) {}
        }, this);
      }
      const after = injected.length ? readBytes(this.data, Math.min(this.cbData, 256)) : before;
      const key = String(this.cbData);
      const oldCount = seen[key] || 0;
      seen[key] = oldCount + 1;
      if (injected.length || oldCount < 4 || before.length) {
        emit('GetDeviceState', {
          device: this.deviceIndex,
          bytes: this.cbData,
          original_nonzero: before,
          injected: injected,
          returned_nonzero: after
        });
      }
    }
  });
  emit('GetDeviceStateHooked', {device: deviceIndex, address: pointerKey(method), bytes: 0});
}

function hookCreateDevice(interfaceObject) {
  if (!validPointer(interfaceObject)) return;
  let vtable;
  try { vtable = interfaceObject.readPointer(); } catch (_) { return; }
  if (!validPointer(vtable)) return;
  const method = vtable.add(Process.pointerSize * 3).readPointer();
  if (!validPointer(method)) return;
  installOnce(method, 'CreateDevice', {
    onEnter: function (args) {
      this.out = args[2];
      emit('CreateDevice', {interface: pointerKey(args[0])});
    },
    onLeave: function (retval) {
      if (retval.toInt32() !== 0 || !validPointer(this.out)) return;
      let device;
      try { device = this.out.readPointer(); } catch (_) { return; }
      if (!validPointer(device)) return;
      const index = Object.keys(hookedFunctions).filter(function (key) {
        return key.indexOf('GetDeviceState:') === 0;
      }).length;
      emit('DeviceCreated', {device: pointerKey(device), device_index: index});
      hookGetDeviceState(device, index);
    }
  });
}

function hookDirectInput8Create() {
  if (directInputHooked) return;
  const address = moduleExport('DirectInput8Create');
  if (!address) return;
  directInputHooked = true;
  Interceptor.attach(address, {
    onEnter: function (args) {
      this.output = args[3];
      emit('DirectInput8Create', {address: pointerKey(address)});
    },
    onLeave: function (retval) {
      let interfaceObject = null;
      if (retval.toInt32() === 0 && validPointer(this.output)) {
        try { interfaceObject = this.output.readPointer(); } catch (_) {}
      }
      emit('DirectInput8CreateReturn', {
        result: retval.toInt32(),
        interface: validPointer(interfaceObject) ? pointerKey(interfaceObject) : '0x0'
      });
      if (validPointer(interfaceObject)) hookCreateDevice(interfaceObject);
    }
  });
  emit('DirectInput8CreateHooked', {address: pointerKey(address)});
}

function hookFileReads() {
  if (readHooksInstalled) return;
  const createA = moduleExport('CreateFileA');
  const createW = moduleExport('CreateFileW');
  const readFile = moduleExport('ReadFile');
  if (!createA || !createW || !readFile) return;
  readHooksInstalled = true;

  installOnce(createA, 'CreateFileA', {
    onEnter: function (args) { this.path = safeReadAnsi(args[0]); },
    onLeave: function (retval) {
      if (retval.toInt32() !== -1 && this.path) {
        handlePaths[pointerKey(retval)] = this.path;
        emit('open', {api: 'CreateFileA', path: this.path, handle: pointerKey(retval)});
      }
    }
  });
  installOnce(createW, 'CreateFileW', {
    onEnter: function (args) { this.path = safeReadUtf16(args[0]); },
    onLeave: function (retval) {
      if (retval.toInt32() !== -1 && this.path) {
        handlePaths[pointerKey(retval)] = this.path;
        emit('open', {api: 'CreateFileW', path: this.path, handle: pointerKey(retval)});
      }
    }
  });
  installOnce(readFile, 'ReadFile', {
    onEnter: function (args) {
      this.handle = pointerKey(args[0]);
      this.buffer = args[1];
      this.requested = safeArgU32(args[2]);
      this.readCount = args[3];
    },
    onLeave: function (retval) {
      if (retval.toInt32() === 0 || !this.readCount) return;
      const bytes = safeReadU32(this.readCount);
      const path = handlePaths[this.handle] || '';
      if (!path || !/RPP_[0-9]+\.pp/i.test(path)) return;
      emit('read', {api: 'ReadFile', path: path, handle: this.handle, requested: this.requested, bytes: bytes});
    }
  });
  emit('ReadHooksInstalled', {});
}

function findGameModule() {
  try {
    return Process.findModuleByName('gameprobe.exe') || Process.findModuleByName('电车之狼R.exe');
  } catch (_) {
    return null;
  }
}

function hookGameFunctions() {
  if (gameHooksInstalled) return;
  const module = findGameModule();
  if (!module) return;
  const base = module.base;
  function relative(address) {
    return base.add(address - 0x00400000);
  }
  const watchedKeys = {1: true, 0x1d: true, 0x9d: true, 0xc8: true, 0xd0: true,
                       0x2c: true, 0x2d: true, 0x39: true, 0x3b: true, 0x3c: true};
  const keyFn = relative(0x00467b90);
  installOnce(keyFn, 'FUN_00467b90', {
    onEnter: function (args) { this.code = safeArgU32(args[0]); },
    onLeave: function (retval) {
      const value = retval.toInt32() & 0xff;
      gameKeyCallCount += 1;
      if (gameKeyCallCount <= 30 || watchedKeys[this.code] || value !== 0) {
        emit('GameKey', {address: '0x00467b90', code: this.code, result: value});
      }
    }
  });
  const inputUpdateFn = relative(0x00467ab0);
  const inputArray = base.add(0x003c83d8);
  installOnce(inputUpdateFn, 'FUN_00467ab0', {
    onLeave: function () {
      const values = [1, 0x2c, 0x2d, 0x3b, 0x3c].map(function (offset) {
        try { return [offset, inputArray.add(offset).readU8()]; } catch (_) { return [offset, -1]; }
      });
      const fingerprint = JSON.stringify(values);
      if (fingerprint !== inputArraySnapshot) {
        inputArraySnapshot = fingerprint;
        emit('InputArray', {address: '0x007c83d8', values: values});
      }
    }
  });
  const menuFn = relative(0x0045f7c0);
  installOnce(menuFn, 'FUN_0045f7c0', {
    onEnter: function (args) {
      if (forceMenu && forceMenuRemaining > 0 && elapsed() < 49) {
        args[1] = ptr(forceMenu.x | 0);
        args[2] = ptr(forceMenu.y | 0);
        args[4] = ptr((forceMenu.input === undefined ? 3 : forceMenu.input) & 0xff);
        forceMenuRemaining -= 1;
        emit('ForceTitleMenu', {x: forceMenu.x | 0, y: forceMenu.y | 0,
                                input: forceMenu.input === undefined ? 3 : forceMenu.input & 0xff,
                                remaining: forceMenuRemaining});
      } else {
        if (!forceGameMenu && forceGameMenuQueue.length && elapsed() >= forceGameMenuQueue[0].at) {
          forceGameMenu = forceGameMenuQueue.shift();
          forceGameMenuRemaining = forceGameMenu.frames || 5;
        }
        if (!forceGameRelease && forceGameReleaseQueue.length && elapsed() >= forceGameReleaseQueue[0].at) {
          forceGameRelease = forceGameReleaseQueue.shift();
          forceGameReleaseRemaining = forceGameRelease.frames || 3;
        }
      }
      if (forceGameMenu && forceGameMenuRemaining > 0 && elapsed() >= forceGameMenu.at) {
        args[1] = ptr(forceGameMenu.x | 0);
        args[2] = ptr(forceGameMenu.y | 0);
        args[4] = ptr((forceGameMenu.input === undefined ? 3 : forceGameMenu.input) & 0xff);
        forceGameMenuRemaining -= 1;
        emit('ForceGameplayMenu', {x: forceGameMenu.x | 0, y: forceGameMenu.y | 0,
                                    input: forceGameMenu.input === undefined ? 3 : forceGameMenu.input & 0xff,
                                    remaining: forceGameMenuRemaining});
        if (!forceGameMenuRemaining) forceGameMenu = null;
      } else if (forceGameRelease && forceGameReleaseRemaining > 0 && elapsed() >= forceGameRelease.at) {
        args[1] = ptr(forceGameRelease.x | 0);
        args[2] = ptr(forceGameRelease.y | 0);
        args[4] = ptr((forceGameRelease.input === undefined ? 1 : forceGameRelease.input) & 0xff);
        forceGameReleaseRemaining -= 1;
        emit('ForceGameplayRelease', {x: forceGameRelease.x | 0, y: forceGameRelease.y | 0,
                                       input: forceGameRelease.input === undefined ? 1 : forceGameRelease.input & 0xff,
                                       remaining: forceGameReleaseRemaining});
        if (!forceGameReleaseRemaining) forceGameRelease = null;
      }
      this.x = safeArgU32(args[1]);
      this.y = safeArgU32(args[2]);
      this.scale = safeArgU32(args[3]);
      this.input = safeArgU32(args[4]);
      const shouldCaptureGeometry = !menuGeometrySent || (elapsed() >= 49 && !gameplayMenuGeometrySent);
      if (shouldCaptureGeometry && validPointer(args[0])) {
        try {
          const count = args[0].add(0x50c).readU32();
          const entries = [];
          for (let index = 0; index < Math.min(count, 8); ++index) {
            entries.push({
              index: index,
              x: args[0].add(0x200 + index * 4).readFloat(),
              y: args[0].add(0x280 + index * 4).readFloat(),
              width: args[0].add(0x400 + index * 4).readFloat(),
              height: args[0].add(0x480 + index * 4).readFloat(),
              disabled: args[0].add(0x710 + index * 4).readU32(),
              press_activate: args[0].add(0x510 + index * 4).readU32(),
              toggle: args[0].add(0x610 + index * 4).readU32()
            });
          }
          emit('MenuGeometry', {count: count, entries: entries});
          if (elapsed() >= 49) gameplayMenuGeometrySent = true;
          else menuGeometrySent = true;
        } catch (_) {}
      }
    },
    onLeave: function (retval) {
      emit('MenuHit', {address: '0x0045f7c0', x: this.x, y: this.y,
                       scale: this.scale, input: this.input, result: retval.toInt32()});
    }
  });
  const hitTestFn = relative(0x0045f600);
  installOnce(hitTestFn, 'FUN_0045f600', {
    onEnter: function (args) {
      this.left = safeArgFloat(args[0]);
      this.top = safeArgFloat(args[1]);
      this.width = safeArgFloat(args[2]);
      this.height = safeArgFloat(args[3]);
      this.x = safeArgS32(args[4]);
      this.y = safeArgS32(args[5]);
      this.scale = safeArgFloat(args[6]);
    },
    onLeave: function (retval) {
      emit('MenuHitTest', {left: this.left, top: this.top, width: this.width,
                           height: this.height, x: this.x, y: this.y,
                           scale: this.scale, result: retval.toInt32()});
    }
  });
  [0x005129c0, 0x00512cc0, 0x00605510, 0x00605d80, 0x00606440].forEach(function (address) {
    const fn = relative(address);
    installOnce(fn, 'FUN_' + address.toString(16), {
      onEnter: function (args) {
        this.sceneArg = args[0];
        emit('GameSceneEnter', {address: '0x' + address.toString(16)});
      },
      onLeave: function () {
        emit('GameSceneLeave', {address: '0x' + address.toString(16)});
        if (address === 0x00605d80 || address === 0x00606440) {
          try {
            const state = {
              address: '0x0078ea68',
              ea68: base.add(0x47ea68).readU8(),
              ea69: base.add(0x47ea69).readU8(),
              ea6c: base.add(0x47ea6c).readU8(),
              e058: base.add(0x47e058).readU8(),
              chapter: validPointer(this.sceneArg) ? this.sceneArg.add(0x13535).readU8() : -1
            };
            const fingerprint = JSON.stringify(state);
            if (fingerprint !== introStateSnapshot) {
              introStateSnapshot = fingerprint;
              emit('IntroState', state);
            }
          } catch (_) {}
        }
      }
    });
  });
  const dispatcherFn = relative(0x0052bcf0);
  installOnce(dispatcherFn, 'FUN_0052bcf0', {
    onEnter: function (args) {
      this.main = args[0];
      this.state = args[1];
      if (forceChapter && !forceChapterApplied && elapsed() >= forceChapter.at &&
          validPointer(this.main) && validPointer(this.state)) {
        try {
          this.main.add(0x13535).writeU8(forceChapter.chapter & 0xff);
          this.state.add(0xbe0).writeU8(1);
          this.state.add(0xbe1).writeU8(1);
          forceChapterApplied = true;
          emit('ForceChapterDispatch', {chapter: forceChapter.chapter & 0xff});
        } catch (_) {}
      }
    },
    onLeave: function () {
      if (!validPointer(this.state)) return;
      try {
        const state = {
          address: '0x0052bcf0',
          be0: this.state.add(0xbe0).readU8(),
          be1: this.state.add(0xbe1).readU8(),
          b2f8: this.state.add(0x2f8).readU8(),
          chapter: validPointer(this.main) ? this.main.add(0x13535).readU8() : -1
        };
        const fingerprint = JSON.stringify(state);
        if (fingerprint !== dispatcherSnapshot) {
          dispatcherSnapshot = fingerprint;
          emit('IntroDispatcher', state);
        }
      } catch (_) {}
    }
  });
  [0x00605b20, 0x00605390].forEach(function (address) {
    const fn = relative(address);
    installOnce(fn, 'FUN_' + address.toString(16), {
      onEnter: function () { emit('IntroHelperEnter', {address: '0x' + address.toString(16)}); },
      onLeave: function () { emit('IntroHelperLeave', {address: '0x' + address.toString(16)}); }
    });
  });
  const audioDispatcherFn = relative(0x00532240);
  installOnce(audioDispatcherFn, 'FUN_00532240', {
    onEnter: function (args) {
      const values = [];
      for (let index = 0; index < 4; ++index) {
        const item = {index: index, pointer: pointerKey(args[index])};
        if (validPointer(args[index])) {
          try {
            item.slot106c = args[index].add(0x106c).readU32();
            item.slot1070 = args[index].add(0x1070).readU32();
            item.state3 = args[index].add(3).readU8();
          } catch (_) {}
        }
        values.push(item);
      }
      const fingerprint = JSON.stringify(values);
      if (fingerprint !== audioDispatcherSnapshot) {
        audioDispatcherSnapshot = fingerprint;
        emit('AudioDispatcher', {address: '0x00532240', values: values});
      }
    }
  });
  [0x00513320, 0x00513690, 0x005179e0, 0x00517a00, 0x00517a20, 0x005319e0].forEach(function (address) {
    const fn = relative(address);
    gameplayCallbackCounts[address] = 0;
    installOnce(fn, 'GameplayCallback_' + address.toString(16), {
      onEnter: function (args) {
        gameplayCallbackCounts[address] += 1;
        const count = gameplayCallbackCounts[address];
        if (address === 0x00513690) {
          try {
            const state = base.add(0x4393b4);
            const bytes = [];
            for (let i = 0; i < 0x80; ++i) bytes.push(state.add(i).readU8());
            const context = base.add(0x437b68);
            const input = args[0];
            const extra = {
              context504: context.add(0x504).readU32(),
              contextF142: context.add(0xf142).readU8(),
              main260: validPointer(input) ? input.add(0x260).readU8() : -1,
              main261: validPointer(input) ? input.add(0x261).readU8() : -1,
              main26c: validPointer(input) ? input.add(0x26c).readU32() : 0
            };
            const controller = base.add(0x44dc28);
            extra.controller3044 = controller.add(0x3044).readU32();
            extra.controller3050 = controller.add(0x3050).readU32();
            extra.controller3054 = controller.add(0x3054).readU32();
            extra.controller3058 = controller.add(0x3058).readU32();
            extra.controller305c = controller.add(0x305c).readU8();
            extra.controller3064 = controller.add(0x3064).readU32();
            const fingerprint = JSON.stringify({bytes: bytes, extra: extra});
            if (fingerprint !== gameplayStateSnapshot) {
              gameplayStateSnapshot = fingerprint;
              emit('GameplayState', {address: '0x008393b4', bytes: bytes, extra: extra});
            }
          } catch (_) {}
        }
        if (address === 0x00513690 && forceDispatch && forceDispatchRemaining > 0 &&
            elapsed() >= forceDispatch.at) {
          try {
            base.add(0x437b68 + 0xf144 + 3).writeU8(3);
            base.add(0x4393b4 + 6).writeU8(3);
            forceDispatchRemaining -= 1;
            emit('ForceAudioDispatch', {remaining: forceDispatchRemaining});
          } catch (_) {}
        }
        if (address === 0x00513690 && forceActions && forceActionsRemaining > 0 &&
            elapsed() >= forceActions.at) {
          try {
            const main = args[0];
            if (validPointer(main)) {
              main.add(0x260).writeU8(3);
              main.add(0x261).writeU8(3);
              main.add(0x26c).writeS32(1);
              const input = base.add(0x4393b4);
              input.add(5).writeU8(1);
              input.add(6).writeU8(0);
              input.add(0x260).writeU8(3);
              input.add(0x261).writeU8(3);
              input.add(0x26c).writeS32(1);
              const context = base.add(0x437b68);
              context.add(0x504).writeS32(2);
              context.add(0xf142).writeU8(0);
              forceActionsRemaining -= 1;
              emit('ForceGameplayActions', {remaining: forceActionsRemaining});
            }
          } catch (_) {}
        }
        if (count <= 3 || elapsed() >= 49) {
          const argPointers=[];
          for (let index=0; index<4; ++index) argPointers.push(pointerKey(args[index]));
          emit('GameplayCallback', {address: '0x' + address.toString(16), count: count,
                                    return_address: pointerKey(this.returnAddress),
                                    args: argPointers});
        }
      },
      onLeave: function () {}
    });
  });
  const mapTransitionFn = relative(0x00598a50);
  installOnce(mapTransitionFn, 'FUN_00598a50', {
    onEnter: function (args) {
      this.main = args[0];
      this.before = {};
      try {
        if (validPointer(this.main)) {
          this.before.map_selector = this.main.add(0x13533).readU8();
          this.before.story_state = this.main.add(0x13535).readU8();
          this.before.character = this.main.add(0x13530).readU8();
        }
        const controller = base.add(0x44dc28);
        this.before.context305c = controller.add(0x305c).readU8();
        this.before.context3064 = controller.add(0x3064).readU8();
      } catch (_) {}
    },
    onLeave: function () {
      const after = {};
      try {
        if (validPointer(this.main)) {
          after.map_selector = this.main.add(0x13533).readU8();
          after.story_state = this.main.add(0x13535).readU8();
          after.character = this.main.add(0x13530).readU8();
        }
        const controller = base.add(0x44dc28);
        after.context305c = controller.add(0x305c).readU8();
        after.context3064 = controller.add(0x3064).readU8();
      } catch (_) {}
      emit('MapTransitionTick', {return_address: pointerKey(this.returnAddress), before: this.before, after: after});
    }
  });
  const mapTransitionGateFn = relative(0x005f9561);
  installOnce(mapTransitionGateFn, 'FUN_005f9561', {
    onEnter: function (args) {
      this.main = args[0];
      this.before = {};
      try {
        if (validPointer(this.main)) {
          this.before.map_selector = this.main.add(0x13533).readU8();
          this.before.story_state = this.main.add(0x13535).readU8();
          this.before.callback = pointerKey(this.main.add(0x21f78).readPointer());
          this.before.mode = this.main.add(0x278).readU8();
        }
      } catch (_) {}
    },
    onLeave: function () {
      const after = {};
      try {
        if (validPointer(this.main)) {
          after.map_selector = this.main.add(0x13533).readU8();
          after.story_state = this.main.add(0x13535).readU8();
          after.callback = pointerKey(this.main.add(0x21f78).readPointer());
          after.mode = this.main.add(0x278).readU8();
        }
      } catch (_) {}
      emit('MapTransitionGate', {return_address: pointerKey(this.returnAddress), before: this.before, after: after});
    }
  });
  const mapContextFn = relative(0x005ffd90);
  installOnce(mapContextFn, 'FUN_005ffd90', {
    onLeave: function (retval) {
      const context = retval;
      if (!validPointer(context)) return;
      try {
        emit('MapContextSnapshot', {
          return_address: pointerKey(this.returnAddress),
          context: pointerKey(context),
          context305c: context.add(0x305c).readU8(),
          context3064: context.add(0x3064).readU8(),
          context3044: context.add(0x3044).readU16()
        });
      } catch (_) {}
    }
  });
  const setMapContextFn = relative(0x005feeb0);
  installOnce(setMapContextFn, 'FUN_005feeb0', {
    onEnter: function (args) {
      const fields = {value: safeArgU32(args[1]), argument: pointerKey(args[0])};
      try {
        const context = base.add(0x47ac60);
        fields.before = context.add(0x305c).readU8();
        fields.counter = context.add(0x3058).readU8();
        const main = args[0];
        if (validPointer(main)) {
          fields.map_selector = main.add(0x13533).readU8();
          fields.story_state = main.add(0x13535).readU8();
        }
      } catch (_) {}
      emit('MapContextSet', fields);
    }
  });
  const gameplayActionFn = relative(0x005fef30);
  installOnce(gameplayActionFn, 'FUN_005fef30', {
    onEnter: function (args) {
      const fields = {argument: pointerKey(args[0]), mode: safeArgU32(args[1]), value: safeArgU32(args[2])};
      try {
        const context = base.add(0x47ac60);
        fields.context305c = context.add(0x305c).readU8();
        fields.context3058 = context.add(0x3058).readU8();
      } catch (_) {}
      emit('GameplayActionDispatch', fields);
    }
  });
  gameHooksInstalled = true;
  emit('GameHooksInstalled', {base: pointerKey(base)});
}

function hookCursorFunctions() {
  if (cursorHooksInstalled) return;
  const getCursorPos = moduleExport('GetCursorPos');
  const setCursorPos = moduleExport('SetCursorPos');
  if (!getCursorPos || !setCursorPos) return;
  cursorHooksInstalled = true;
  installOnce(getCursorPos, 'GetCursorPos', {
    onEnter: function (args) { this.point = args[0]; },
    onLeave: function (retval) {
      if (retval.toInt32() === 0 || !validPointer(this.point)) return;
      try { emit('GetCursorPos', {x: this.point.readS32(), y: this.point.add(4).readS32()}); } catch (_) {}
    }
  });
  installOnce(setCursorPos, 'SetCursorPos', {
    onEnter: function (args) {
      emit('SetCursorPos', {x: safeArgU32(args[0]), y: safeArgU32(args[1])});
    }
  });
  emit('CursorHooksInstalled', {});
}

function poll() {
  if (!moduleSnapshotSent) {
    try {
      emit('modules', {names: Process.enumerateModules().map(function (module) { return module.name; })});
    } catch (_) {}
    moduleSnapshotSent = true;
  }
  hookDirectInput8Create();
  hookFileReads();
  hookGameFunctions();
  hookCursorFunctions();
}

emit('agent_ready', {pointer_size: Process.pointerSize});
setInterval(poll, 25);
poll();
