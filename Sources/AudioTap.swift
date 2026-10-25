import Foundation
import CoreAudio
import AudioToolbox

// MARK: - Helper Core Audio

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    var result = value
    let err = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
    return err == noErr ? result : nil
}

func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var str: CFString? = nil
    let err = withUnsafeMutablePointer(to: &str) {
        AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
    }
    guard err == noErr, let str else { return nil }
    return str as String
}

func readObjectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = address(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
    return list
}

func defaultOutputDeviceUID() -> String? {
    guard let dev = readValue(systemObject, kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID(0)),
          dev != kAudioObjectUnknown else { return nil }
    return readString(dev, kAudioDevicePropertyDeviceUID)
}

/// Un processo che ha un client audio attivo in Core Audio.
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isPlaying: Bool
}

func listAudioProcesses() -> [AudioProcess] {
    readObjectList(systemObject, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
        guard let pid = readValue(obj, kAudioProcessPropertyPID, default: pid_t(0)) else { return nil }
        let running = readValue(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) ?? 0
        return AudioProcess(objectID: obj, pid: pid,
                            bundleID: readString(obj, kAudioProcessPropertyBundleID),
                            isPlaying: running != 0)
    }
}

/// PID dell'app "responsabile" di un processo di supporto (es. Safari per com.apple.WebKit.GPU).
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

func responsiblePID(for pid: pid_t) -> pid_t {
    guard let fn = responsibleFn else { return pid }
    let r = fn(pid)
    return r > 0 ? r : pid
}

// MARK: - Tap per app

/// Cattura l'audio di un gruppo di processi (zittendo l'originale) e lo
/// rimanda all'uscita di default con un guadagno regolabile.
final class AppTap {
    let processIDs: Set<AudioObjectID>
    let outputUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// [0] = guadagno desiderato, [1] = guadagno attuale (per rampe senza click)
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 2)
    private let queue = DispatchQueue(label: "VolumeMixer.io", qos: .userInteractive)

    init?(processIDs: Set<AudioObjectID>, outputUID: String, gain initial: Float) {
        self.processIDs = processIDs
        self.outputUID = outputUID
        gain[0] = initial
        gain[1] = initial

        let desc = CATapDescription(stereoMixdownOfProcesses: Array(processIDs))
        desc.uuid = UUID()
        desc.name = "VolumeMixer"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else {
            NSLog("VolumeMixer: creazione tap fallita")
            return nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else {
            NSLog("VolumeMixer: creazione dispositivo aggregato fallita")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let g = gain
        let err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
            AppTap.render(input, output, g)
        }
        guard err == noErr, AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            NSLog("VolumeMixer: avvio IO fallito")
            stop()
            return nil
        }
    }

    deinit {
        stop()
        gain.deallocate()
    }

    func setGain(_ value: Float) { gain[0] = value }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: Render (thread audio: niente allocazioni)

    /// Puntatore al canale `channel` (contando su tutti i buffer) e relativo passo.
    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ channel: Int) -> (UnsafeMutablePointer<Float>, Int)? {
        var first = 0
        for buf in list {
            let n = Int(buf.mNumberChannels)
            if channel < first + n, let data = buf.mData {
                return (data.assumingMemoryBound(to: Float.self) + (channel - first), n)
            }
            first += n
        }
        return nil
    }

    /// Sopra 1.0 di guadagno applica un soft-clip per evitare distorsioni dure.
    @inline(__always)
    private static func limit(_ x: Float) -> Float {
        let a = abs(x)
        if a <= 0.8 { return x }
        let y = 0.8 + 0.2 * tanh((a - 0.8) / 0.2)
        return x < 0 ? -y : y
    }

    private static func render(_ inPtr: UnsafePointer<AudioBufferList>,
                               _ outPtr: UnsafeMutablePointer<AudioBufferList>,
                               _ gain: UnsafeMutablePointer<Float>) {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inPtr))
        let output = UnsafeMutableAudioBufferListPointer(outPtr)

        for buf in output where buf.mData != nil {
            memset(buf.mData, 0, Int(buf.mDataByteSize))
        }

        var inChannels = 0
        for buf in input { inChannels += Int(buf.mNumberChannels) }
        guard inChannels > 0, input[0].mNumberChannels > 0 else { return }

        var frames = Int(input[0].mDataByteSize) / (4 * Int(input[0].mNumberChannels))
        for buf in output where buf.mNumberChannels > 0 {
            frames = min(frames, Int(buf.mDataByteSize) / (4 * Int(buf.mNumberChannels)))
        }
        guard frames > 0 else { return }

        let target = gain[0]
        let start = gain[1]
        let step = (target - start) / Float(frames)
        let boost = max(target, start) > 1.0

        var outChannel = 0
        for buf in output {
            let stride = Int(buf.mNumberChannels)
            defer { outChannel += stride }
            guard let out = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for c in 0..<stride {
                guard let (src, srcStride) = channel(input, (outChannel + c) % inChannels) else { continue }
                var g = start
                for f in 0..<frames {
                    g += step
                    let s = src[f * srcStride] * g
                    out[f * stride + c] = boost ? limit(s) : s
                }
            }
        }
        gain[1] = target
    }
}
