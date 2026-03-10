import Foundation

/// Detects project frameworks from files in a directory and suggests dev commands.
public struct FrameworkDetector {
    public struct DetectedFramework {
        public let name: String
        public let command: String
        public let arguments: [String]
    }

    public init() {}

    /// Detect frameworks in a directory and return suggested sessions.
    public func detect(in directory: String) -> [DetectedFramework] {
        let fm = FileManager.default
        var results: [DetectedFramework] = []

        // Node.js / JS frameworks
        if fm.fileExists(atPath: "\(directory)/package.json") {
            if fm.fileExists(atPath: "\(directory)/next.config.js") ||
               fm.fileExists(atPath: "\(directory)/next.config.mjs") ||
               fm.fileExists(atPath: "\(directory)/next.config.ts") {
                results.append(DetectedFramework(name: "Next.js", command: "npm", arguments: ["run", "dev"]))
            } else if fm.fileExists(atPath: "\(directory)/nuxt.config.ts") ||
                      fm.fileExists(atPath: "\(directory)/nuxt.config.js") {
                results.append(DetectedFramework(name: "Nuxt", command: "npm", arguments: ["run", "dev"]))
            } else if fm.fileExists(atPath: "\(directory)/svelte.config.js") {
                results.append(DetectedFramework(name: "SvelteKit", command: "npm", arguments: ["run", "dev"]))
            } else if fm.fileExists(atPath: "\(directory)/remix.config.js") ||
                      fm.fileExists(atPath: "\(directory)/remix.config.ts") {
                results.append(DetectedFramework(name: "Remix", command: "npm", arguments: ["run", "dev"]))
            } else if fm.fileExists(atPath: "\(directory)/astro.config.mjs") ||
                      fm.fileExists(atPath: "\(directory)/astro.config.ts") {
                results.append(DetectedFramework(name: "Astro", command: "npm", arguments: ["run", "dev"]))
            } else if fm.fileExists(atPath: "\(directory)/vite.config.ts") ||
                      fm.fileExists(atPath: "\(directory)/vite.config.js") {
                results.append(DetectedFramework(name: "Vite", command: "npm", arguments: ["run", "dev"]))
            } else {
                results.append(DetectedFramework(name: "Node.js", command: "npm", arguments: ["start"]))
            }
        }

        // Python
        if fm.fileExists(atPath: "\(directory)/pyproject.toml") ||
           fm.fileExists(atPath: "\(directory)/requirements.txt") {
            if fm.fileExists(atPath: "\(directory)/manage.py") {
                results.append(DetectedFramework(name: "Django", command: "python", arguments: ["manage.py", "runserver"]))
            } else {
                // Check for FastAPI/Flask in pyproject.toml
                results.append(DetectedFramework(name: "Python", command: "python", arguments: ["-m", "uvicorn", "main:app", "--reload"]))
            }
        }

        // Ruby / Rails
        if fm.fileExists(atPath: "\(directory)/Gemfile") {
            if fm.fileExists(atPath: "\(directory)/bin/rails") {
                results.append(DetectedFramework(name: "Rails", command: "bin/rails", arguments: ["server"]))
            }
        }

        // Rust
        if fm.fileExists(atPath: "\(directory)/Cargo.toml") {
            results.append(DetectedFramework(name: "Rust", command: "cargo", arguments: ["run"]))
        }

        // Go
        if fm.fileExists(atPath: "\(directory)/go.mod") {
            results.append(DetectedFramework(name: "Go", command: "go", arguments: ["run", "."]))
        }

        // Swift
        if fm.fileExists(atPath: "\(directory)/Package.swift") {
            results.append(DetectedFramework(name: "Swift", command: "swift", arguments: ["run"]))
        }

        // .NET
        if let contents = try? fm.contentsOfDirectory(atPath: directory),
           contents.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") }) {
            results.append(DetectedFramework(name: ".NET", command: "dotnet", arguments: ["run"]))
        }

        // Elixir / Phoenix
        if fm.fileExists(atPath: "\(directory)/mix.exs") {
            if fm.fileExists(atPath: "\(directory)/lib/\((directory as NSString).lastPathComponent)_web") {
                results.append(DetectedFramework(name: "Phoenix", command: "mix", arguments: ["phx.server"]))
            } else {
                results.append(DetectedFramework(name: "Elixir", command: "mix", arguments: ["run"]))
            }
        }

        // Docker
        if fm.fileExists(atPath: "\(directory)/docker-compose.yml") ||
           fm.fileExists(atPath: "\(directory)/docker-compose.yaml") ||
           fm.fileExists(atPath: "\(directory)/compose.yml") ||
           fm.fileExists(atPath: "\(directory)/compose.yaml") {
            results.append(DetectedFramework(name: "Docker Compose", command: "docker", arguments: ["compose", "up"]))
        }

        // Laravel
        if fm.fileExists(atPath: "\(directory)/artisan") {
            results.append(DetectedFramework(name: "Laravel", command: "php", arguments: ["artisan", "serve"]))
        }

        return results
    }
}
