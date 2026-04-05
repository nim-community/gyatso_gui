import std/times

var
  audioEnabled = true
  lastPlayTime = 0.0
  minInterval = 0.05

proc canPlay(): bool =
  let now = epochTime()
  if now - lastPlayTime < minInterval:
    return false
  lastPlayTime = now
  return true

const placedWavData = staticRead("../../assets/placed.wav")

when defined(macosx):
  {.passL: "-framework AppKit".}

  type
    SEL = pointer
    Class = pointer

  proc objc_getClass(name: cstring): Class {.header: "<objc/runtime.h>", importc.}
  proc sel_registerName(name: cstring): SEL {.header: "<objc/objc.h>", importc.}

  type
    MsgSend0 = proc(self: pointer, op: SEL): pointer {.cdecl.}
    MsgSend1 = proc(self: pointer, op: SEL, arg1: pointer): pointer {.cdecl.}
    MsgSend2 = proc(self: pointer, op: SEL, arg1: pointer, arg2: culong): pointer {.cdecl.}

  proc objc_msgSend(): pointer {.header: "<objc/message.h>", importc.}

  var
    class_NSData: Class = nil
    class_NSSound: Class = nil
    sel_dataWithBytesLength: SEL = nil
    sel_alloc: SEL = nil
    sel_initWithData: SEL = nil
    sel_play: SEL = nil

  proc initSelectors() =
    if class_NSData == nil:
      class_NSData = objc_getClass("NSData")
      class_NSSound = objc_getClass("NSSound")
      sel_dataWithBytesLength = sel_registerName("dataWithBytes:length:")
      sel_alloc = sel_registerName("alloc")
      sel_initWithData = sel_registerName("initWithData:")
      sel_play = sel_registerName("play")

  var gWavData = placedWavData

  proc playPlacedSound*() =
    if not audioEnabled or not canPlay():
      return

    initSelectors()

    let dataObj = cast[MsgSend2](objc_msgSend)(class_NSData, sel_dataWithBytesLength, addr gWavData[0], gWavData.len.culong)
    if dataObj == nil:
      return

    let alloced = cast[MsgSend0](objc_msgSend)(class_NSSound, sel_alloc)
    if alloced == nil:
      return

    let sound = cast[MsgSend1](objc_msgSend)(alloced, sel_initWithData, dataObj)
    if sound == nil:
      return

    discard cast[MsgSend0](objc_msgSend)(sound, sel_play)

elif defined(linux):
  type
    snd_pcm_t = pointer
    snd_pcm_stream_t = enum
      SND_PCM_STREAM_PLAYBACK = 0
    snd_pcm_format_t = enum
      SND_PCM_FORMAT_S16_LE = 2
      SND_PCM_FORMAT_U8 = 1
    snd_pcm_uframes_t = culong
    snd_pcm_sframes_t = clong

  {.passL: "-lasound".}

  proc snd_pcm_open(pcm: ptr snd_pcm_t, name: cstring, stream: snd_pcm_stream_t, mode: int32): int32 {.importc, header: "<alsa/asoundlib.h>".}
  proc snd_pcm_set_params(pcm: snd_pcm_t, format: snd_pcm_format_t, access: int32, channels: uint32, rate: uint32, soft_resample: int32, latency: uint32): int32 {.importc, header: "<alsa/asoundlib.h>".}
  proc snd_pcm_writei(pcm: snd_pcm_t, buffer: pointer, size: snd_pcm_uframes_t): snd_pcm_sframes_t {.importc, header: "<alsa/asoundlib.h>".}
  proc snd_pcm_drain(pcm: snd_pcm_t): int32 {.importc, header: "<alsa/asoundlib.h>".}
  proc snd_pcm_close(pcm: snd_pcm_t): int32 {.importc, header: "<alsa/asoundlib.h>".}

  type
    WavHeader = object
      audioFormat: uint16
      numChannels: uint16
      sampleRate: uint32
      bitsPerSample: uint16

  proc parseWav(data: string): tuple[sampleRate: uint32, channels: uint32, bits: uint32, pcmOffset: int, pcmSize: int] =
    if data.len < 44:
      return (0'u32, 0'u32, 0'u32, 0, 0)

    var header: WavHeader
    copyMem(addr header, unsafeAddr data[20], 16)

    var offset = 44
    while offset < data.len - 8:
      var chunkId: array[4, char]
      var chunkSize: uint32
      copyMem(addr chunkId, unsafeAddr data[offset], 4)
      copyMem(addr chunkSize, unsafeAddr data[offset + 4], 4)

      if chunkId == ['d', 'a', 't', 'a']:
        return (header.sampleRate, header.numChannels.uint32, header.bitsPerSample.uint32, offset + 8, chunkSize.int)

      offset += 8 + chunkSize.int

    return (0'u32, 0'u32, 0'u32, 0, 0)

  proc playPlacedSound*() =
    if not audioEnabled or not canPlay():
      return

    let data = placedWavData
    if data.len < 44:
      return

    let (sampleRate, channels, bits, pcmOffset, pcmSize) = parseWav(data)
    if pcmSize <= 0 or pcmOffset + pcmSize > data.len:
      return

    var pcm: snd_pcm_t = nil
    if snd_pcm_open(addr pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0:
      return

    let format = if bits == 8: SND_PCM_FORMAT_U8 else: SND_PCM_FORMAT_S16_LE
    let access = 3

    if snd_pcm_set_params(pcm, format, access, channels, sampleRate, 1, 500000) < 0:
      discard snd_pcm_close(pcm)
      return

    let chunkSize = 4096
    var offset = pcmOffset
    var remaining = pcmSize

    while remaining > 0:
      let toWrite = min(chunkSize, remaining)
      let frames = toWrite div (bits div 8).int div channels.int
      let written = snd_pcm_writei(pcm, unsafeAddr data[offset], frames.snd_pcm_uframes_t)
      if written < 0:
        break
      offset += toWrite
      remaining -= toWrite

    discard snd_pcm_drain(pcm)
    discard snd_pcm_close(pcm)

elif defined(windows):
  type
    HMODULE = pointer

  const
    SND_MEMORY = 0x4
    SND_ASYNC = 0x1
    SND_NODEFAULT = 0x2

  proc PlaySoundW(pszSound: pointer, hmod: HMODULE, fdwSound: uint32): bool {.stdcall, dynlib: "winmm.dll", importc.}

  proc playPlacedSound*() =
    if not audioEnabled or not canPlay():
      return

    let wpath = placedWavData.cstring
    discard PlaySoundW(addr wpath[0], nil, SND_MEMORY or SND_ASYNC or SND_NODEFAULT)

else:
  proc playPlacedSound*() =
    discard

proc setAudioEnabled*(enabled: bool) =
  audioEnabled = enabled

proc setMinInterval*(seconds: float) =
  minInterval = seconds
