import XCTest

/// Decisions of the app edition's "Move to Applications" check (Shared/InstallLocationPlan.swift).
final class InstallLocationPlanTests: XCTestCase {
    private let home = "/Users/ada"

    func testPlace() {
        XCTAssertEqual(InstallLocationPlan.place(bundlePath: "/Applications/TokenMaccer.app", home: home, readOnly: false),
                       .applications)
        XCTAssertEqual(InstallLocationPlan.place(bundlePath: "/Applications/Tools/TokenMaccer.app/", home: home,
                                                 readOnly: false), .applications, "subfolder, trailing slash")
        XCTAssertEqual(InstallLocationPlan.place(bundlePath: "/Users/ada/Applications/TokenMaccer.app", home: home,
                                                 readOnly: false), .applications, "the user's own Applications folder")
        XCTAssertEqual(InstallLocationPlan.place(
            bundlePath: "/private/var/folders/xy/T/AppTranslocation/3F2A-11/d/TokenMaccer.app", home: home, readOnly: true),
                       .translocated)
        XCTAssertEqual(InstallLocationPlan.place(bundlePath: "/Volumes/TokenMaccer/TokenMaccer.app", home: home,
                                                 readOnly: true), .readOnlyVolume, "the DMG")
        XCTAssertEqual(InstallLocationPlan.place(bundlePath: "/Users/ada/Downloads/TokenMaccer.app", home: home,
                                                 readOnly: false), .elsewhere)
        // a folder that only starts like Applications is not it
        XCTAssertEqual(InstallLocationPlan.place(bundlePath: "/ApplicationsOld/TokenMaccer.app", home: home,
                                                 readOnly: false), .elsewhere)
        XCTAssertEqual(InstallLocationPlan.place(bundlePath: "/Applications/../Users/ada/Desktop/TokenMaccer.app",
                                                 home: home, readOnly: false), .elsewhere, "path is standardised first")
    }

    func testOfferOnlyInTheAppEditionOutsideApplications() {
        XCTAssertTrue(InstallLocationPlan.shouldOffer(place: .translocated, isApp: true, enabled: true, debugBuild: false))
        XCTAssertTrue(InstallLocationPlan.shouldOffer(place: .readOnlyVolume, isApp: true, enabled: true, debugBuild: false))
        XCTAssertTrue(InstallLocationPlan.shouldOffer(place: .elsewhere, isApp: true, enabled: true, debugBuild: false))
        XCTAssertFalse(InstallLocationPlan.shouldOffer(place: .applications, isApp: true, enabled: true, debugBuild: false))
        XCTAssertFalse(InstallLocationPlan.shouldOffer(place: .elsewhere, isApp: false, enabled: true, debugBuild: false),
                       "open-source edition runs from its build folder")
        XCTAssertFalse(InstallLocationPlan.shouldOffer(place: .elsewhere, isApp: true, enabled: false, debugBuild: false))
        XCTAssertFalse(InstallLocationPlan.shouldOffer(place: .elsewhere, isApp: true, enabled: true, debugBuild: true))
    }

    func testSwitch() {
        XCTAssertTrue(InstallLocationPlan.isEnabled(defaultsValue: nil))
        XCTAssertTrue(InstallLocationPlan.isEnabled(defaultsValue: "on"))
        XCTAssertFalse(InstallLocationPlan.isEnabled(defaultsValue: "off"))
    }

    func testDestinationAndOriginal() {
        let dest = InstallLocationPlan.destination(bundleName: "TokenMaccer.app")
        XCTAssertEqual(dest, "/Applications/TokenMaccer.app")
        XCTAssertTrue(InstallLocationPlan.trashOriginal(originalPath: "/Users/ada/Downloads/TokenMaccer.app",
                                                        originalReadOnly: false, destination: dest))
        XCTAssertFalse(InstallLocationPlan.trashOriginal(originalPath: "/Volumes/TokenMaccer/TokenMaccer.app",
                                                         originalReadOnly: true, destination: dest), "DMG is ejected")
        XCTAssertFalse(InstallLocationPlan.trashOriginal(originalPath: "/Applications/TokenMaccer.app/",
                                                         originalReadOnly: false, destination: dest), "never the copy")
    }

    func testEjectOnlyADiskImage() {
        let mounts = ["/Volumes/TokenMaccer", "/Volumes/TokenMaccer 1"]
        XCTAssertEqual(InstallLocationPlan.diskImageToEject(path: "/Volumes/TokenMaccer/TokenMaccer.app",
                                                            imageMountPoints: mounts), "/Volumes/TokenMaccer")
        XCTAssertEqual(InstallLocationPlan.diskImageToEject(path: "/Volumes/TokenMaccer 1/TokenMaccer.app",
                                                            imageMountPoints: mounts), "/Volumes/TokenMaccer 1")
        XCTAssertNil(InstallLocationPlan.diskImageToEject(path: "/Volumes/USB/TokenMaccer.app", imageMountPoints: mounts),
                     "an external disk is not ejected")
        XCTAssertNil(InstallLocationPlan.diskImageToEject(path: "/Users/ada/Downloads/TokenMaccer.app",
                                                          imageMountPoints: ["/"]), "never the root volume")
    }
}
