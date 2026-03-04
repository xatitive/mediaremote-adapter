import Foundation

public class MediaController {

    private var perlScriptPath: String? {
        guard let path = Bundle.module.path(forResource: "run", ofType: "pl") else {
            assertionFailure("run.pl script not found in bundle resources.")
            return nil
        }
        return path
    }

    private var watchProcess: Process?
    private var watchDataBuffer = Data()
    private var seekDebounceItem: DispatchWorkItem?
    private var fetchDebounceItem: DispatchWorkItem?
    private var fetchGeneration: UInt = 0

    /// The most recently received track info. Read `currentTrackInfo?.payload.currentElapsedTime`
    /// to compute the current playback position on demand without any timers.
    public private(set) var currentTrackInfo: TrackInfo?

    public var onTrackInfoReceived: ((TrackInfo?) -> Void)?
    public var onListenerTerminated: (() -> Void)?
    public var onDecodingError: ((Error, Data) -> Void)?
    public var bundleIdentifier: String?

    public init(bundleIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
    }

    private var libraryPath: String? {
        let bundle = Bundle(for: MediaController.self)
        guard let path = bundle.executablePath else {
            assertionFailure("Could not locate the executable path for the MediaRemoteAdapter framework.")
            return nil
        }
        return path
    }

    @discardableResult
    private func runPerlCommand(arguments: [String]) -> (output: String?, error: String?, terminationStatus: Int32) {
        guard let scriptPath = perlScriptPath else {
            return (nil, "Perl script not found.", -1)
        }
        guard let libraryPath = libraryPath else {
            return (nil, "Dynamic library path not found.", -1)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptPath, libraryPath] + arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            return (output, errorOutput, process.terminationStatus)
        } catch {
            return (nil, error.localizedDescription, -1)
        }
    }

    /// Returns the track info independently from the actual listen process.
    public func getTrackInfo(_ onReceive: @escaping (TrackInfo?) -> Void) {
        guard let scriptPath = perlScriptPath else {
            onReceive(nil)
            return
        }
        guard let libraryPath = libraryPath else {
            onReceive(nil)
            return
        }

        let getProcess = Process()
        getProcess.executableURL = URL(fileURLWithPath: "/usr/bin/perl")

        var getDataBuffer = Data()
        var callbackExecuted = false

        var arguments = [scriptPath]
        if let bundleId = bundleIdentifier {
            arguments.append("--id")
            arguments.append(bundleId)
        }
        arguments.append(contentsOf: [libraryPath, "get"])
        getProcess.arguments = arguments

        let outputPipe = Pipe()
        getProcess.standardOutput = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak outputPipe] fileHandle in
            let incomingData = fileHandle.availableData
            if incomingData.isEmpty {
                // EOF — pipe closed. Stop the handler to prevent a spin loop.
                outputPipe?.fileHandleForReading.readabilityHandler = nil
                return
            }

            getDataBuffer.append(incomingData)

            guard let newlineData = "\n".data(using: .utf8),
                  let range = getDataBuffer.firstRange(of: newlineData),
                  range.lowerBound <= getDataBuffer.count else {
                return
            }

            let lineData = getDataBuffer.subdata(in: 0..<range.lowerBound)
            getDataBuffer.removeSubrange(0..<range.upperBound)

            if !lineData.isEmpty && !callbackExecuted {
                callbackExecuted = true
                outputPipe?.fileHandleForReading.readabilityHandler = nil
                // Check for NIL response
                if lineData == "NIL".data(using: .utf8) {
                    DispatchQueue.main.async { onReceive(nil) }
                    return
                }
                do {
                    let trackInfo = try JSONDecoder().decode(TrackInfo.self, from: lineData)
                    DispatchQueue.main.async { onReceive(trackInfo) }
                } catch {
                    DispatchQueue.main.async { onReceive(nil) }
                }
            }
        }

        getProcess.terminationHandler = { _ in
            outputPipe.fileHandleForReading.readabilityHandler = nil
            if !callbackExecuted {
                DispatchQueue.main.async { onReceive(nil) }
            }
        }

        do {
            try getProcess.run()
        } catch {
            onReceive(nil)
        }
    }
    
    /// returns current playback time (seconds) independently from the listen process.
    public func getPlaybackTime(_ onReceive: @escaping (TimeInterval?) -> Void) {
        guard let scriptPath = perlScriptPath else { onReceive(nil); return }
        guard let libraryPath = libraryPath else { onReceive(nil); return }

        let getProcess = Process()
        getProcess.executableURL = URL(fileURLWithPath: "/usr/bin/perl")

        var getDataBuffer = Data()
        var callbackExecuted = false

        var arguments = [scriptPath]
        if let bundleId = bundleIdentifier {
            arguments.append("--id")
            arguments.append(bundleId)
        }
        arguments.append(contentsOf: [libraryPath, "get"])
        getProcess.arguments = arguments

        let outputPipe = Pipe()
        getProcess.standardOutput = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let incomingData = fileHandle.availableData
            if incomingData.isEmpty { return }

            getDataBuffer.append(incomingData)

            guard let newlineData = "\n".data(using: .utf8),
                let range = getDataBuffer.firstRange(of: newlineData),
                range.lowerBound <= getDataBuffer.count
            else { return }

            let lineData = getDataBuffer.subdata(in: 0..<range.lowerBound)
            getDataBuffer.removeSubrange(0..<range.upperBound)

            guard !callbackExecuted else { return }
            callbackExecuted = true

            // nil means “no player”
            if lineData == "NIL".data(using: .utf8) {
                DispatchQueue.main.async { onReceive(nil) }
                return
            }

            do {
                let trackInfo = try JSONDecoder().decode(TrackInfo.self, from: lineData)
                if let micros = trackInfo.payload.elapsedTimeMicros {
                    DispatchQueue.main.async { onReceive(TimeInterval(micros) / 1_000_000) }
                } else {
                    DispatchQueue.main.async { onReceive(nil) }
                }
            } catch {
                DispatchQueue.main.async { onReceive(nil) }
            }
        }

        getProcess.terminationHandler = { _ in
            if !callbackExecuted {
                DispatchQueue.main.async { onReceive(nil) }
            }
        }

        do { try getProcess.run() } catch { onReceive(nil) }
    }

    public func startListening() {
        guard watchProcess == nil else {
            return
        }

        startWatchProcess()

        // Fetch current state immediately so we don't wait for the first notification.
        fetchCurrentTrackInfo()
    }

    /// Starts a lightweight process that emits "CHANGED" signals when media
    /// state changes. No data fetching happens in this process — it only
    /// watches for MediaRemote notifications.
    private func startWatchProcess() {
        guard let scriptPath = perlScriptPath else {
            return
        }
        guard let libraryPath = libraryPath else {
            return
        }

        watchProcess = Process()
        watchProcess?.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        watchProcess?.qualityOfService = .background

        var arguments = [scriptPath]
        if let bundleId = bundleIdentifier {
            arguments.append("--id")
            arguments.append(bundleId)
        }
        arguments.append(contentsOf: [libraryPath, "watch"])
        watchProcess?.arguments = arguments

        let outputPipe = Pipe()
        watchProcess?.standardOutput = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = {
            [weak self, weak outputPipe] fileHandle in
            guard let self = self else { return }

            let incomingData = fileHandle.availableData
            if incomingData.isEmpty {
                // EOF — pipe closed. Stop the handler to prevent a spin loop.
                outputPipe?.fileHandleForReading.readabilityHandler = nil
                return
            }

            self.watchDataBuffer.append(incomingData)

            guard let newlineData = "\n".data(using: .utf8) else { return }
            while let range = self.watchDataBuffer.firstRange(of: newlineData) {
                guard range.lowerBound <= self.watchDataBuffer.count else { break }

                let lineData = self.watchDataBuffer.subdata(in: 0..<range.lowerBound)
                self.watchDataBuffer.removeSubrange(0..<range.upperBound)

                if lineData == "CHANGED".data(using: .utf8) {
                    self.scheduleFetch()
                }
            }
        }

        watchProcess?.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.watchProcess = nil
                self?.onListenerTerminated?()
            }
        }

        do {
            try watchProcess?.run()
        } catch {
            print("Failed to start watch process: \(error)")
            watchProcess = nil
        }
    }

    /// Debounces rapid "CHANGED" signals to avoid spawning too many `get` processes.
    private func scheduleFetch() {
        fetchDebounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fetchCurrentTrackInfo()
        }
        fetchDebounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
    }

    /// Spawns a short-lived `get` process to fetch the current track info.
    /// Uses a generation counter to ignore stale responses from older fetches.
    private func fetchCurrentTrackInfo() {
        fetchGeneration &+= 1
        let generation = fetchGeneration

        getTrackInfo { [weak self] trackInfo in
            guard let self = self else { return }
            guard generation == self.fetchGeneration else { return }

            self.currentTrackInfo = trackInfo
            self.onTrackInfoReceived?(trackInfo)
        }
    }

    public func stopListening() {
        watchProcess?.terminate()
        watchProcess = nil
        fetchDebounceItem?.cancel()
        seekDebounceItem?.cancel()
    }

    public func play() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["play"])
        }
    }

    public func pause() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["pause"])
        }
    }

    public func togglePlayPause() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["toggle_play_pause"])
        }
    }

    public func nextTrack() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["next_track"])
        }
    }

    public func previousTrack() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["previous_track"])
        }
    }
    
    public func stop() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["stop"])
        }
    }

    public func setTime(seconds: Double) {
        seekDebounceItem?.cancel()

        // Throttle the actual seek command to avoid overwhelming the system.
        let item = DispatchWorkItem { [weak self] in
            self?.runPerlCommand(arguments: ["set_time", String(seconds)])
        }
        seekDebounceItem = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05, execute: item)
    }
    
    public func setShuffleMode(_ mode: TrackInfo.ShuffleMode) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["set_shuffle_mode", String(mode.rawValue)])
        }
    }

    public func setRepeatMode(_ mode: TrackInfo.RepeatMode) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.runPerlCommand(arguments: ["set_repeat_mode", String(mode.rawValue)])
        }
    }

}
