import AppKit
import QuotaDockCore

/// Bundled brand artwork is shared by all accounts of a tool. No remote image requests.
@MainActor
enum ToolBranding {
    private static var images: [String: NSImage] = [:]

    static func brandID(for tool: ToolDefinition) -> String? {
        tool.resolvedBrandID
    }

    static func image(for tool: ToolDefinition) -> NSImage? {
        guard let id = brandID(for: tool), !id.contains("/"), !id.contains("..") else { return nil }
        if let cached = images[id] { return cached }
        for ext in ["png", "svg", "ico"] {
            guard let url = AppBranding.resourceBundle?.url(forResource: id, withExtension: ext, subdirectory: "ToolLogos"),
                  let image = NSImage(contentsOf: url), image.isValid else { continue }
            image.isTemplate = false
            image.accessibilityDescription = tool.name
            images[id] = image
            return image
        }
        return nil
    }

    static func makeView(for tool: ToolDefinition?, size: CGFloat = 20) -> NSImageView {
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(tool?.name ?? "自定义工具")
        if let tool, let artwork = image(for: tool) {
            view.image = artwork
            // A small neutral tile keeps dark artwork legible in either macOS appearance.
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.white.cgColor
            view.layer?.cornerRadius = 4
            view.layer?.masksToBounds = true
        } else {
            view.image = NSImage(systemSymbolName: tool?.symbol ?? "square.stack.3d.up", accessibilityDescription: tool?.name)
                ?? NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
            view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .medium)
            view.contentTintColor = .controlAccentColor
        }
        return view
    }
}
