import FieldnoteKit
import Testing

/// Cases taken from a real meeting's notes (Apple's model, 68 minutes).
@Suite("Note quality")
struct NoteQualityTests {

    @Test("Real questions stay; fragments copied from the transcript go")
    func questions() {
        for kept in [
            "How involved is the migration process from VendorA to VendorB?",
            "Is ITDR a paid option?",
            "Do you guys catch ClickFix?",
            "Which partner migrated 15,000 devices",
        ] {
            #expect(NoteQuality.isQuestion(kept), "\(kept)")
        }
        for dropped in [
            "VendorC.",
            "Sorry. Back up.",
            "So if you're using...",
            "Also Microsoft products.",
            "Is that correct?",
            "It's just a spreadsheet of everything at times.",
        ] {
            #expect(!NoteQuality.isQuestion(dropped), "\(dropped)")
        }
    }

    @Test("Decisions are statements of what was agreed")
    func decisions() {
        #expect(NoteQuality.isDecision("Discuss pricing in another meeting."))
        #expect(NoteQuality.isDecision("VendorB EDR is cheaper than VendorA's EDR for this setup."))
        #expect(!NoteQuality.isDecision("I agree as well."))
        #expect(NoteQuality.isDecision("Ship it"))
        #expect(!NoteQuality.isDecision("Which is a bit,"))
        #expect(!NoteQuality.isDecision("No specific decisions were made"))
        #expect(NoteQuality.isDecision("No final decision made; continue research and think it over"))
    }

    @Test("Placeholder owners become no owner")
    func owners() {
        #expect(NoteQuality.owner("None") == nil)
        #expect(NoteQuality.owner("Unassigned") == nil)
        #expect(NoteQuality.owner(" unknown ") == nil)
        #expect(NoteQuality.owner("Jordan") == "Jordan")
    }

    @Test("Near repeats are dropped")
    func repeats() {
        var seen: [Set<String>] = []
        #expect(NoteQuality.isNew("How does VendorC work together with VendorB?", among: &seen))
        #expect(!NoteQuality.isNew("How does VendorC work together with VendorB", among: &seen))
        #expect(!NoteQuality.isNew("how does vendorc and vendorb work together?", among: &seen))
        #expect(NoteQuality.isNew("What's the pricing on ITDR?", among: &seen))
    }

    @Test("Filler lines are recognised; lines with content aren't")
    func filler() {
        for line in ["Okay.", "Yeah, yeah.", "Morning.", "Give us a second.", "Thank you.", "Okay, cool."] {
            #expect(NoteQuality.isFiller(line), "\(line)")
        }
        for line in ["We'll send the pricing on Friday.", "Okay, so the rollback needs backups?", "VendorC."] {
            #expect(!NoteQuality.isFiller(line), "\(line)")
        }
    }

    @Test("A point that repeats its cited line word for word is a quote, a paraphrase isn't")
    func quotes() {
        #expect(NoteQuality.isQuote("Yeah, I do agree", of: "Yeah, I do agree."))
        #expect(NoteQuality.isQuote("my one password and now it's gone", of: "my one password and now it's gone"))
        #expect(!NoteQuality.isQuote("Rollback doesn't use backups; the agent keeps copies",
                                     of: "Actually, the rollback changes is not rely on any backups."))
        #expect(!NoteQuality.isQuote("Pricing goes to another meeting", of: "Let's discuss the pricing details in another meeting, okay?"))
    }
}
