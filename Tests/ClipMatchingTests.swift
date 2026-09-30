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
        ("it-never-ends", "E_Vez_aKIyI"),
        ("vybirat-chudo", "RjObnc58fAM"),
        ("espresso-cover", "afGqwfRPU58"),
        ("stay-at-your-house", "_AAdae7diOU"),
        ("bag-of-grins", nil),
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

    test("a remastered or 4K upload beats the original on the same channel") {
        let track = TrackQuery(id: "t", artist: "Rick Astley", name: "Never Gonna Give You Up", seconds: 213)
        let original = Candidate(id: "o", title: "Rick Astley - Never Gonna Give You Up (Official Video)",
                                 channel: "Rick Astley", duration: 213, isVerified: true)
        let remaster = Candidate(id: "r", title: "Rick Astley - Never Gonna Give You Up (Official Video) (4K Remaster)",
                                 channel: "Rick Astley", duration: 213, isVerified: true)
        expectEqual(ClipMatching.pick(for: track, from: [original, remaster])?.id, "r")
    }

    test("a bare verified upload counts only as YouTube's top result") {
        let track = TrackQuery(id: "t", artist: "Bring Me The Horizon", name: "It Never Ends", seconds: 274)
        let label = Candidate(id: "l", title: "Bring Me The Horizon - \"It Never Ends\"",
                              channel: "Epitaph Records", duration: 281, isVerified: true)
        let fan = Candidate(id: "f", title: "Bring Me The Horizon - It Never Ends (HQ)",
                            channel: "Some Fan", duration: 276, isVerified: false)
        expectEqual(ClipMatching.pick(for: track, from: [label, fan])?.id, "l")
        expectEqual(ClipMatching.pick(for: track, from: [fan, label])?.id, nil)
    }

    test("the first of several Spotify artists is the one matched") {
        let track = TrackQuery(id: "t", artist: "Samuel Kim, Lorien", name: "Stay", seconds: 200)
        let video = Candidate(id: "v", title: "Samuel Kim - Stay (Official Video)", channel: "Someone",
                              duration: 200, isVerified: false)
        expectEqual(ClipMatching.score(video, for: track), 4)
    }

    test("a cover is fine on the artist's own channel only") {
        let track = TrackQuery(id: "t", artist: "First to Eleven", name: "Espresso", seconds: 175)
        let own = Candidate(id: "o", title: "Espresso - Sabrina Carpenter (Cover by First To Eleven)",
                            channel: "First To Eleven", duration: 210, isVerified: true)
        let other = Candidate(id: "x", title: "Espresso - Sabrina Carpenter (Cover by First To Eleven)",
                              channel: "Fan Covers", duration: 210, isVerified: true)
        expectEqual(ClipMatching.score(own, for: track), 4)
        expectEqual(ClipMatching.score(other, for: track), nil)
    }
}
