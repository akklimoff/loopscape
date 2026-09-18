import Foundation

func matchingTests() {
    let expectedPicks: [(slug: String, videoID: String?)] = [
        ("get-lucky", "of1XzU7-PHk"),
        ("luchshaya-noch", "AtKMvNUEPMM"),
        ("505", "iIfl5k2nQBQ"),
        ("blinding-lights", "4NRXx6U8ABQ"),
        ("treefingers", nil),
        ("bad-guy", "DyDfgMOUjCI"),
        ("gruppa-krovi", "MAn_WoXZ-hk"),
        ("never-gonna", "dQw4w9WgXcQ"),
        ("audio", "tjA7nAHOAww"),
        ("live-forever", "TDe1DqxwJoc"),
    ]
    for (slug, videoID) in expectedPicks {
        test("pick: \(slug)") {
            let fixture = try loadFixture(slug)
            expectEqual(ClipMatching.pick(for: fixture.track, from: fixture.candidates)?.id, videoID)
        }
    }

    test("normalize folds case, diacritics and punctuation") {
        expectEqual(ClipMatching.normalize("  Beyoncé — P!nk / AC/DC  "), "beyonce p nk ac dc")
        expectEqual(ClipMatching.normalize("МакSим - Лучшая НОЧЬ"), "макsим лучшая ночь")
    }

    test("cleanTrackName drops Spotify decorations") {
        expectEqual(ClipMatching.cleanTrackName("Get Lucky (feat. Pharrell Williams & Nile Rodgers)"), "Get Lucky")
        expectEqual(ClipMatching.cleanTrackName("Live Forever - Remastered"), "Live Forever")
        expectEqual(ClipMatching.cleanTrackName("Song [Bonus Track] - 2011 Remaster"), "Song")
        expectEqual(ClipMatching.cleanTrackName("(Untitled)"), "(Untitled)")
    }

    test("searchQuery uses the cleaned name") {
        let track = TrackQuery(id: "t", artist: "Oasis", name: "Live Forever - Remastered", seconds: 276)
        expectEqual(ClipMatching.searchQuery(for: track), "Oasis Live Forever official video")
    }

    let audio = TrackQuery(id: "t", artist: "LSD", name: "Audio", seconds: 191)

    test("a rejected word in the track's own name is forgiven once") {
        let video = Candidate(id: "v", title: "LSD - Audio (Official Video)", channel: "Sia",
                              duration: 226, isVerified: true)
        let cover = Candidate(id: "a", title: "LSD - Audio (Official Audio)", channel: "Sia",
                              duration: 191, isVerified: true)
        expectEqual(ClipMatching.score(video, for: audio), 4)
        expectEqual(ClipMatching.score(cover, for: audio), nil)
    }

    test("art tracks on Topic channels are rejected") {
        let artTrack = Candidate(id: "v", title: "LSD - Audio (Official Video)", channel: "LSD - Topic",
                                 duration: 191, isVerified: true)
        expectEqual(ClipMatching.score(artTrack, for: audio), nil)
    }

    test("the same title by another artist is rejected") {
        let other = Candidate(id: "v", title: "Audio (Official Music Video)", channel: "Somebody Else",
                              duration: 191, isVerified: true)
        expectEqual(ClipMatching.score(other, for: audio), nil)
    }

    test("durations far from the track are rejected, unknown track length is not") {
        let loop = Candidate(id: "v", title: "LSD - Audio (Official Video) 1 Hour", channel: "LSD",
                             duration: 3600, isVerified: false)
        let video = Candidate(id: "v", title: "LSD - Audio (Official Video)", channel: "LSD",
                              duration: 3600, isVerified: false)
        let unknownLength = TrackQuery(id: "t", artist: "LSD", name: "Audio", seconds: 0)
        expectEqual(ClipMatching.score(loop, for: audio), nil)
        expectEqual(ClipMatching.score(video, for: audio), nil)
        expectEqual(ClipMatching.score(video, for: unknownLength), 6)
    }

    test("an official channel upload without a marker clears the threshold") {
        let track = TrackQuery(id: "t", artist: "Billie Eilish", name: "bad guy", seconds: 194)
        let upload = Candidate(id: "v", title: "Billie Eilish - bad guy", channel: "Billie Eilish",
                               duration: 206, isVerified: false)
        let stranger = Candidate(id: "s", title: "Billie Eilish - bad guy", channel: "Some Fan",
                                 duration: 194, isVerified: true)
        expectEqual(ClipMatching.score(upload, for: track), 3)
        expectEqual(ClipMatching.score(stranger, for: track), nil)
    }
}
