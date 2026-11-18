import Darwin
import XCTest
import Zsign
@testable import Signet

@_silgen_name("proc_regionfilename")
private func proc_regionfilename(_ pid: Int32, _ address: UInt64, _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> Int32

/// zsign must release the memory mappings it makes when inspecting binaries, or a deleted app keeps its disk space
/// until Signet quits.
final class ZsignMappingTests: XCTestCase {
    /// Memory regions in this process that map `path`.
    private func mappings(of path: String) -> Int {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var count = 0
        var address: vm_address_t = 0
        var size: vm_size_t = 0
        var info = vm_region_basic_info_data_64_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
        var object: mach_port_t = 0
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        while withUnsafeMutablePointer(to: &info, {
            $0.withMemoryRebound(to: Int32.self, capacity: Int(infoCount)) {
                vm_region_64(mach_task_self_, &address, &size, VM_REGION_BASIC_INFO_64, $0, &infoCount, &object)
            }
        }) == KERN_SUCCESS {
            let length = proc_regionfilename(getpid(), UInt64(address), &buffer, UInt32(buffer.count))
            if length > 0, String(decoding: buffer.prefix(Int(length)), as: UTF8.self) == target { count += 1 }
            address += size
            infoCount = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<Int32>.size)
        }
        return count
    }

    func testInspectingABinaryReleasesItsMapping() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("FixtureTweak.dylib")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Run scripts/make-test-fixtures.sh first.") }
        let copy = try Paths.newTempDirectory().appendingPathComponent("Inspect.dylib")
        defer { Paths.removeIfTemporary(copy) }
        try FileManager.default.copyItem(at: fixture, to: copy)

        for _ in 0..<5 {
            XCTAssertFalse(Zsign.listDylibs(appExecutable: copy.path).isEmpty)
            _ = Zsign.checkSigned(appExecutable: copy.path)
        }
        XCTAssertEqual(mappings(of: copy.path), 0, "every inspection unmaps the file")
    }
}
