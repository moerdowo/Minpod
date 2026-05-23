import XCTest
@testable import MinpodKit

final class RoundTripTests: XCTestCase {

    // MARK: fixture builders (raw iTunesDB-shaped bytes with correct lengths)

    private func stringMHOD(type: UInt32, _ s: String) -> [UInt8] {
        let utf16 = Array(s.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] }
        let w = ByteWriter()
        w.appendMagic("mhod")
        w.appendUInt32(24)                       // header len
        w.appendUInt32(UInt32(24 + 16 + utf16.count)) // total len
        w.appendUInt32(type)
        w.appendUInt32(0)
        w.appendUInt32(0)
        // string body: position, byte-length, encoding, unk, then UTF-16LE
        w.appendUInt32(1)
        w.appendUInt32(UInt32(utf16.count))
        w.appendUInt32(0)
        w.appendUInt32(0)
        w.append(utf16)
        return w.bytes
    }

    private func mhit(id: UInt32, lengthMS: UInt32, mhods: [[UInt8]]) -> [UInt8] {
        let headerLen = 0x9C
        let body = mhods.flatMap { $0 }
        let w = ByteWriter()
        w.appendMagic("mhit")
        w.appendUInt32(UInt32(headerLen))
        w.appendUInt32(UInt32(headerLen + body.count)) // total len
        w.appendUInt32(UInt32(mhods.count))            // mhod count
        w.appendUInt32(id)                             // track id @16
        while w.count < 0x28 { w.appendUInt8(0) }
        w.appendUInt32(lengthMS)                       // length @0x28
        while w.count < headerLen { w.appendUInt8(0) }
        w.append(body)
        return w.bytes
    }

    private func listHeader(_ magic: String, count: Int, headerLen: Int) -> [UInt8] {
        let w = ByteWriter()
        w.appendMagic(magic)
        w.appendUInt32(UInt32(headerLen))
        w.appendUInt32(UInt32(count))
        while w.count < headerLen { w.appendUInt8(0) }
        return w.bytes
    }

    private func mhsd(type: UInt32, payload: [UInt8]) -> [UInt8] {
        let headerLen = 0x60
        let w = ByteWriter()
        w.appendMagic("mhsd")
        w.appendUInt32(UInt32(headerLen))
        w.appendUInt32(UInt32(headerLen + payload.count))
        w.appendUInt32(type)
        while w.count < headerLen { w.appendUInt8(0) }
        w.append(payload)
        return w.bytes
    }

    private func mhbd(children: [[UInt8]]) -> [UInt8] {
        let headerLen = 0x68
        let body = children.flatMap { $0 }
        let w = ByteWriter()
        w.appendMagic("mhbd")
        w.appendUInt32(UInt32(headerLen))
        w.appendUInt32(UInt32(headerLen + body.count))
        w.appendUInt32(1)                       // unk1
        w.appendUInt32(0x13)                     // version
        w.appendUInt32(UInt32(children.count))   // child count
        while w.count < headerLen { w.appendUInt8(0) }
        w.append(body)
        return w.bytes
    }

    private func sampleDB() -> [UInt8] {
        let t1 = mhit(id: 101, lengthMS: 215000, mhods: [
            stringMHOD(type: MHODType.title.rawValue, "Hello World"),
            stringMHOD(type: MHODType.artist.rawValue, "The Artist"),
            stringMHOD(type: MHODType.album.rawValue, "An Album"),
            stringMHOD(type: MHODType.location.rawValue, ":iPod_Control:Music:F00:ABCD.mp3"),
        ])
        let t2 = mhit(id: 102, lengthMS: 90000, mhods: [
            stringMHOD(type: MHODType.title.rawValue, "Track Two"),
        ])
        let trackList = listHeader("mhlt", count: 2, headerLen: 0x5C) + t1 + t2
        let ds1 = mhsd(type: 1, payload: trackList)
        let playlists = listHeader("mhlp", count: 0, headerLen: 0x5C)
        let ds2 = mhsd(type: 2, payload: playlists)
        return mhbd(children: [ds1, ds2])
    }

    // MARK: tests

    func testRoundTripIsByteExact() throws {
        let original = sampleDB()
        let db = try ITunesDB.parse(Data(original))
        XCTAssertEqual(db.serialize(), original, "serialize(parse(x)) must equal x")
        XCTAssertTrue(db.roundTripsExactly())
    }

    func testTrackExtraction() throws {
        let db = try ITunesDB.parse(Data(sampleDB()))
        XCTAssertEqual(db.tracks.count, 2)
        let first = db.tracks[0]
        XCTAssertEqual(first.id, 101)
        XCTAssertEqual(first.title, "Hello World")
        XCTAssertEqual(first.artist, "The Artist")
        XCTAssertEqual(first.album, "An Album")
        XCTAssertEqual(first.lengthMS, 215000)
        XCTAssertEqual(first.ipodPath, ":iPod_Control:Music:F00:ABCD.mp3")
        XCTAssertEqual(db.tracks[1].title, "Track Two")
    }

    func testAppendingTrackRecomputesLengths() throws {
        // Inserting a new mhit and bumping the mhlt count should re-serialize into
        // a file whose enclosing total-lengths are recomputed so it re-parses.
        let db = try ITunesDB.parse(Data(sampleDB()))
        let newMhitBytes = mhit(id: 103, lengthMS: 60000, mhods: [
            stringMHOD(type: MHODType.title.rawValue, "Added Song"),
        ])
        let newMhit = try ChunkParser(newMhitBytes).parse()
        let mhlt = try XCTUnwrap(db.trackListHeader)
        mhlt.children.append(newMhit)

        let out = db.serialize()
        let reparsed = try ITunesDB.parse(Data(out))
        XCTAssertEqual(reparsed.tracks.count, 3)
        XCTAssertEqual(reparsed.tracks.last?.title, "Added Song")
        // Total length of the whole file must equal the actual byte count.
        XCTAssertEqual(Int(le32(out, 8)), out.count)
    }
}
