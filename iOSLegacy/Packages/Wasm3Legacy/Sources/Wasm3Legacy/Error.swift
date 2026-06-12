//
//  Error.swift
//  Wasm3
//
//  Created by Skitty on 6/18/23.
//

import Foundation
import wasm3_legacy_c

public enum Wasm3Error: LocalizedError, CustomStringConvertible, Equatable {
    case failedAllocation
    case invalidMemoryAccess
    case invalidSignature
    case mismatchedEnvironments
    case missingFunction

    // parse errors
    case incompatibleWasmVersion
    case wasmUnderrun

    // link errors
    case functionLookupFailed
    case missingImportedFunction

    // fallback
    case wasm3Error(String)

    init(ffiResult: M3Result, runtime: IM3Runtime? = nil) {
        let detail = Self.runtimeErrorMessage(from: runtime)

        switch ffiResult {
            case m3Err_incompatibleWasmVersion:
                self = .incompatibleWasmVersion
            case m3Err_wasmUnderrun:
                self = .wasmUnderrun
            case m3Err_functionLookupFailed:
                self = .functionLookupFailed
            case m3Err_functionImportMissing:
                if let detail {
                    self = .wasm3Error("missing imported function: \(detail)")
                } else {
                    self = .missingImportedFunction
                }
            default:
                let string = String(cString: ffiResult)
                if string == "function signature mismatch" {
                    self = .invalidSignature
                } else if let detail, detail != string {
                    self = .wasm3Error("\(string): \(detail)")
                } else {
                    self = .wasm3Error(string)
                }
        }
    }

    public var errorDescription: String? {
        switch self {
            case .failedAllocation:
                return "Unable to allocate WASM runtime memory."
            case .invalidMemoryAccess:
                return "The WASM source tried to access invalid memory."
            case .invalidSignature:
                return "A WASM host function has an incompatible signature."
            case .mismatchedEnvironments:
                return "The WASM module was loaded into the wrong runtime environment."
            case .missingFunction:
                return "The WASM source is missing the requested function."
            case .incompatibleWasmVersion:
                return "The WASM source uses an unsupported WASM version."
            case .wasmUnderrun:
                return "The WASM source file is incomplete or corrupted."
            case .functionLookupFailed:
                return "The requested WASM function could not be found."
            case .missingImportedFunction:
                return "The WASM source requires a host function that AidokuLegacy does not provide."
            case .wasm3Error(let message):
                return message.isEmpty ? "The WASM runtime failed." : message
        }
    }

    public var description: String {
        errorDescription ?? "The WASM runtime failed."
    }

    private static func runtimeErrorMessage(from runtime: IM3Runtime?) -> String? {
        guard let runtime else { return nil }

        var info = M3ErrorInfo()
        m3_GetErrorInfo(runtime, &info)

        var parts: [String] = []
        if let message = info.message {
            let value = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                parts.append(value)
            }
        }
        if let function = info.function {
            let value = String(cString: m3_GetFunctionName(function))
            if !value.isEmpty {
                parts.append("function \(value)")
            }
        }
        if let file = info.file, info.line > 0 {
            let value = String(cString: file)
            if !value.isEmpty {
                parts.append("\(value):\(info.line)")
            }
        }

        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// TODO: traps https://docs.rs/wasm3/0.3.1/src/wasm3/error.rs.html
