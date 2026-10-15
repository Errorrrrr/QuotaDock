import AppKit

@MainActor
enum AppBranding {
    static let resourceBundle: Bundle? = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("QuotaDock_QuotaDock.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        return Bundle.module
    }()

    static func icon(size: CGFloat, template: Bool = false) -> NSImage? {
        let name = template ? "StatusTemplate" : "AppIcon"
        guard let url = resourceBundle?.url(forResource: name, withExtension: "png", subdirectory: "Branding"),
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = template
        image.accessibilityDescription = "QuotaDock"
        return image
    }
}
