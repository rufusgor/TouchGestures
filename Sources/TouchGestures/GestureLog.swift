// GestureLog.swift — журнал для отладки распознавания жестов.
// Включается так (затем перезапустить приложение):
//   defaults write app.TouchGestures DebugLog -bool true
// Пишет в ~/Library/Logs/TouchGestures/gestures.log (новый файл при каждом запуске):
//   R t n id x y …   — сырой кадр от панели (t — аппаратная метка, с);
//   S t n id x y …   — кадр после выравнивания по экрану;
//   E t текст        — решение эмулятора: нажатие кнопки, начало прокрутки, масштаб и т.д.

import Foundation
import QuartzCore
import TouchCore

final class GestureLog {
    static let shared = GestureLog()

    private let file: FileHandle?
    private var buffer = ""

    var isEnabled: Bool { file != nil }

    private init() {
        guard UserDefaults.standard.bool(forKey: "DebugLog") else { file = nil; return }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TouchGestures")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("gestures.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.flush() }
    }

    func frame(_ kind: Character, _ touches: [TouchPoint]) {
        guard isEnabled else { return }
        var line = String(format: "%@ %.4f %d", String(kind), touches.first?.timestamp ?? CACurrentMediaTime(), touches.count)
        for t in touches { line += String(format: " %d %.1f %.1f", t.id, t.location.x, t.location.y) }
        buffer += line + "\n"
    }

    func event(_ text: String) {
        guard isEnabled else { return }
        buffer += String(format: "E %.4f ", CACurrentMediaTime()) + text + "\n"
    }

    func flush() {
        guard let file, !buffer.isEmpty else { return }
        file.write(buffer.data(using: .utf8)!)
        buffer = ""
    }
}
