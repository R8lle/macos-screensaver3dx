import Foundation
import ScreenSaver

/// Available 3D models and their runtime selection.
///
/// Three bundled models (bundle resources), custom 3D text
/// (`TextMeshGenerator`), a custom GLB file (`GlbMesh`), and a custom
/// USDZ file (`UsdzImport`) -- the latter three are converted at runtime
/// into cached OBJ+MTL, which use the same loading pipeline.
struct ModelSpec {
    let modelID: String
    let displayName: String
    let objName: String
}

enum ModelRegistry {
    static let modelKey = "model"
    static let defaultModelID = "ralle_logo"
    static let textModelID = "custom_text"
    static let glbModelID = "custom_glb"
    static let usdzModelID = "custom_usdz"

    static let choices: [ModelSpec] = [
        ModelSpec(modelID: "ralle_logo", displayName: "R@lle", objName: "ralle_logo.obj"),
        ModelSpec(modelID: "spaceship", displayName: "Raumschiff", objName: "spaceship.obj"),
        ModelSpec(modelID: "teapot", displayName: "Utah-Teekanne", objName: "teapot.obj"),
        // obj_name is never used directly (see objURL(for:)) -- just a
        // fallback identifier in case runtime generation fails.
        ModelSpec(modelID: textModelID, displayName: "Eigener 3D-Text", objName: "ralle_logo.obj"),
        ModelSpec(modelID: glbModelID, displayName: "Eigene GLB-Datei", objName: "ralle_logo.obj"),
        ModelSpec(modelID: usdzModelID, displayName: "Eigene USDZ-Datei", objName: "ralle_logo.obj"),
    ]

    private static let validIDs = Set(choices.map(\.modelID))
    private static let byID = Dictionary(uniqueKeysWithValues: choices.map { ($0.modelID, $0) })

    static func readModelID(screenID: Int32?) -> String {
        let defaults = Defaults.store
        for key in [ScreenRegistry.scopedKey(modelKey, screenID: screenID), modelKey] {
            if let value = defaults.string(forKey: key) {
                if value == "logo" { return defaultModelID }
                if validIDs.contains(value) { return value }
            }
        }
        return defaultModelID
    }

    static func writeModelID(_ modelID: String, screenID: Int32?) {
        let resolved = validIDs.contains(modelID) ? modelID : defaultModelID
        let defaults = Defaults.store
        defaults.set(resolved, forKey: ScreenRegistry.scopedKey(modelKey, screenID: screenID))
        defaults.synchronize()
    }

    static func objURL(for modelID: String, screenID: Int32?) -> URL? {
        var resolvedID = modelID
        // Runtime-generated models: fall back to the default model on any
        // error (missing font, file not selectable/corrupt) instead of
        // crashing.
        switch modelID {
        case textModelID:
            if let generated = TextMeshGenerator.ensureTextModel(text: Defaults.readCustomText(screenID: screenID)) {
                return generated
            }
            resolvedID = defaultModelID
        case glbModelID:
            let path = Defaults.readCustomGlbPath(screenID: screenID)
            if !path.isEmpty,
               let generated = GlbMesh.ensureGlbModel(sourcePath: path, bookmark: Defaults.readCustomGlbBookmark(screenID: screenID)) {
                return generated
            }
            resolvedID = defaultModelID
        case usdzModelID:
            let path = Defaults.readCustomUsdzPath(screenID: screenID)
            if !path.isEmpty,
               let generated = UsdzImport.ensureUsdzModel(sourcePath: path, bookmark: Defaults.readCustomUsdzBookmark(screenID: screenID)) {
                return generated
            }
            resolvedID = defaultModelID
        default:
            break
        }
        let spec = byID[resolvedID] ?? byID[defaultModelID]!
        let bundle = Bundle(for: TeapotMesh.self)
        let name = (spec.objName as NSString).deletingPathExtension
        return bundle.url(forResource: name, withExtension: "obj")
    }
}
