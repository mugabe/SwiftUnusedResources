import Foundation
import Glob
import PathKit
import Rainbow
import XcodeProj
import Yams

public final class Explorer {
    private let projectPath: Path
    private let sourceRoot: Path
    private let target: String?
    private let showWarnings: Bool
    private let excludedResources: [String]
    private let excludedSources: [Path]
    private let excludedAssets: [String]
    private let kinds: Set<ExploreKind>

    private let storage = Storage()
    
    public init(
        projectPath: Path,
        sourceRoot: Path,
        target: String?,
        showWarnings: Bool
    ) throws {
        self.projectPath = projectPath
        self.sourceRoot = sourceRoot
        self.target = target
        self.showWarnings = showWarnings
        
        let configuration = Self.configuration(from: sourceRoot + "sur.yml")
        
        excludedSources = configuration?.exclude?.sources?
            .map { Path($0) }
            .map { $0.isAbsolute ? $0 : sourceRoot + $0 }
            ?? []
        
        excludedResources = configuration?.exclude?.resources ?? []
        excludedAssets = configuration?.exclude?.assets ?? []
        
        kinds = Set(configuration?.kinds?.map { $0.toKind() } ?? ExploreKind.allCases)
    }
    
    public func explore() async throws {
        print("🔨 Loading project \(projectPath.lastComponent)".bold)
        let xcodeproj = try XcodeProj(path: projectPath)
        
        for target in xcodeproj.pbxproj.nativeTargets {
            if self.target == nil || (self.target != nil && target.name == self.target) {
                print("📦 Processing target \(target.name)".bold)
                try await explore(target: target)
            }
        }
        
        print("🦒 Complete".bold)
    }
    
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func analyze() async throws {
        let exploredResources = await storage.exploredResources
        let exploredUsages = await storage.exploredUsages
        
        for resource in exploredResources {
            var usageCount = 0
            
            if excludedResources.contains(resource.name) {
                continue
            }
            
            for usage in exploredUsages where usage.kind == resource.kind {
                switch usage {
                case .string(let value, _):
                    if resource.name == value {
                        usageCount += 1
                    }
                    
                case .regexp(let pattern, _):
                    let regex = try NSRegularExpression(pattern: "^\(pattern)$")
                    
                    let range = NSRange(location: 0, length: resource.name.utf16.count)
                    if regex.firstMatch(in: resource.name, options: [], range: range) != nil {
                        usageCount += 1
                    }
                    
                case .rswift(let identifier, _):
                    let rswift = SwiftIdentifier(name: resource.name)
                    if rswift.description == identifier {
                        usageCount += 1
                    }
                    
                case .generated(let identifier, _):
                    let name = SwiftIdentifier(name: resource.name).description.withoutImageAndColor()
                    
                    if name == identifier {
                        usageCount += 1
                    }
                }
            }
            
            if usageCount == 0 {
                switch resource.type {
                case .asset(let assets):
                    if showWarnings {
                        var name = resource.name
                        if resource.path.starts(with: assets) {
                            name = NSString(string: String(resource.path.dropFirst(assets.count + 1))).deletingPathExtension
                        }
                        
                        print("\(assets): warning: '\(name)' never used")
                    }
                    await storage.addUnused(resource)
                    
                case .file:
                    if showWarnings {
                        print("\(resource.path): warning: '\(resource.name)' never used")
                    }
                    await storage.addUnused(resource)
                }
            }
        }
        
        if !showWarnings {
            let unused = await storage.unused
            if !unused.isEmpty {
                print("    \(unused.count) unused images found".yellow.bold)
                var totalSize = 0
                unused.forEach { resource in
                    var name = resource.path
                    if name.starts(with: sourceRoot.string) {
                        name = String(resource.path.dropFirst(sourceRoot.string.count + 1))
                    }
                    
                    let size = Path(resource.path).size
                    print("     \(size.humanFileSize.padding(toLength: 10, withPad: " ", startingAt: 0)) \(name)")
                    totalSize += size
                }
                print("    \(totalSize.humanFileSize) total".yellow)
            }
            else {
                print("    No unused images found".lightGreen)
            }
        }
    }
    
    private func explore(target: PBXNativeTarget) async throws {
        await storage.clean()
        
        guard let resources = try target.resourcesBuildPhase() else {
            // no sources, skip
            print("    No resources, skip")
            return
        }
        try await explore(resources: resources)
        
        if let sources = try target.sourcesBuildPhase() {
            try await explore(sources: sources)
        }
        
        if let synchronizedGroups = target.fileSystemSynchronizedGroups {
            try await explore(groups: synchronizedGroups)
        }
        
        try await analyze()
    }
    
    private func explore(groups: [PBXFileSystemSynchronizedRootGroup]) async throws {
        for group in groups {
            guard let path = try group.fullPath(sourceRoot: sourceRoot) else {
                continue
            }
            
            let extensions = ["png", "jpg", "pdf", "gif", "svg", "xcassets", "xib", "storyboard"]
            
            for ext in extensions {
                for resource in Glob(pattern: path.string + "**/*.\(ext)") {
                    if ext != "xcassets" && resource.contains("xcassets") {
                        continue
                    }
                    
                    try await explore(resource: Path(resource))
                }
            }
            
            let sources = Glob(pattern: path.string + "**/*.swift")
                .map { Path($0) }
            
            try await explore(files: sources)
        }
    }
    
    private func explore(resource: PBXFileElement) async throws {
        guard let fullPath = try resource.fullPath(sourceRoot: sourceRoot) else {
            throw ExploreError.notFound(message: "Could not get full path for resource \(resource) (uuid: \(resource.uuid))")
        }
        
        try await explore(resource: fullPath)
    }
    
    private func explore(resource path: Path) async throws {
        let ext = path.extension
        
        switch ext {
        case "png", "jpg", "pdf", "gif", "svg":
            try await explore(image: path)
            
        case "xcassets":
            try await explore(xcassets: path)
            
        case "xib", "storyboard":
            try await explore(xib: path)
            
        default:
            break
        }
    }
    
    private func explore(resources: PBXResourcesBuildPhase) async throws {
        guard let files = resources.files else {
            throw ExploreError.notFound(message: "Resource files not found")
        }
        
        for file in files {
            guard let resource = file.file else {
                continue
            }
            
            try await explore(resource: resource)
        }
    }
    
    private func explore(resources: some Sequence<Path>) async throws {
        for resource in resources {
            try await explore(resource: resource)
        }
    }
    
    private func explore(xib path: Path) async throws {
        let parser = XibParser()
        
        let usages = try? parser.parse(path)
        
        guard let usages else {
            return
        }
        
        await storage.addUsages(usages)
    }
    
    private func explore(xcassets path: Path) async throws {
        let resources = kinds
            .flatMap { explore(xcassets: path, kind: $0) }
        
        await storage.addResources(resources)
    }
    
    private func explore(xcassets path: Path, kind: ExploreKind) -> [ExploreResource] {
        guard !excludedAssets.contains(path.lastComponentWithoutExtension) else {
            return []
        }
        
        let resources = Glob(pattern: path.string + kind.assets)
            .map { Path($0) }
            .map {
                ExploreResource(
                    name: $0.lastComponentWithoutExtension,
                    type: .asset(assets: path.string),
                    kind: kind,
                    path: $0.absolute().string
                )
            }
        
        return resources
    }
    
    private func explore(image path: Path) async throws {
        let resource = ExploreResource(
            name: path.lastComponentWithoutExtension,
            type: .file,
            kind: .image,
            path: path.string
        )
        
        await storage.addResource(resource)
    }
    
    private func explore(sources: PBXSourcesBuildPhase) async throws {
        guard let files = sources.files else {
            throw ExploreError.notFound(message: "Source files not found")
        }
        
        let paths = try files.compactMap { try $0.file?.fullPath(sourceRoot: sourceRoot) }
        
        try await explore(files: paths)
    }
    
    private func explore(files: some Sequence<Path>) async throws {
        let parser = SwiftParser(showWarnings: showWarnings, kinds: kinds)
        
        let usages = try await withThrowingTaskGroup(of: [ExploreUsage].self) { group in
            files.forEach { path in
                if path.extension != "swift" {
                    return
                }
                
                if excludedSources.contains(path) {
                    return
                }
                
                let url = path.url
                
                group.addTask { @Sendable in
                    try parser.parse(url)
                }
            }
            
            return try await group.reduce(into: [], +=)
        }
        
        await storage.addUsages(usages)
    }
}

private extension Explorer {
    enum ExploreError: Error {
        case notFound(message: String)
    }
}

private extension Explorer {
    static func configuration(using decoder: YAMLDecoder = .init(), from path: Path) -> Configuration? {
        let data = try? Data(contentsOf: path.url)
        return data.flatMap { try? decoder.decode(Configuration.self, from: $0) }
    }
}

private extension ExploreKind {
    var assets: String {
        switch self {
        case .image: "**/*.imageset"
        case .color: "**/*.colorset"
        }
    }
}

private extension ExploreUsage {
    var kind: ExploreKind {
        switch self {
        case .string(_, let kind): kind
        case .regexp(_, let kind): kind
        case .rswift(_, let kind): kind
        case .generated(_, let kind): kind
        }
    }
}

private extension Configuration.Kind {
    func toKind() -> ExploreKind {
        switch self {
        case .image: .image
        case .color: .color
        }
    }
}

private extension String {
    func withoutImageAndColor() -> String {
        let input = self
        let pattern = "(?i)(image|color)+$"
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(location: 0, length: input.utf16.count)
        let modifiedString = regex?.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
        return modifiedString ?? input
    }
}
