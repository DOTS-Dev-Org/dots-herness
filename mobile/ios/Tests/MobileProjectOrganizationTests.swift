import XCTest
@testable import HerNessMobile

final class MobileProjectOrganizationTests: XCTestCase {
    func testGroupsProjectsBySourceAndPreservesDefaultOrder() {
        let projects = [
            project("github", name: "Zeta", source: .github),
            project("local-a", name: "Beta", source: .local),
            project("desktop", name: "Gamma", source: .remoteDesktop),
            project("local-b", name: "Alpha", source: .local),
        ]

        let groups = MobileProjectOrganization.groups(projects, groupBySource: true, sortByName: false)

        XCTAssertEqual(groups.map(\.key), ["local", "github", "remoteDesktop"])
        XCTAssertEqual(groups[0].projects.map(\.id), ["local-a", "local-b"])
    }

    func testSortsByNameWithoutGrouping() {
        let projects = [project("b", name: "Beta"), project("a", name: "alpha")]

        let groups = MobileProjectOrganization.groups(projects, groupBySource: false, sortByName: true)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].projects.map(\.id), ["a", "b"])
    }

    private func project(
        _ id: String,
        name: String,
        source: MobileProject.SourceKind = .local
    ) -> MobileProject {
        MobileProject(
            id: id,
            name: name,
            sourceKind: source,
            repository: nil,
            branch: nil,
            localRoot: "/workspace/\(id)",
            remoteProjectID: nil,
            remoteWorkspaceID: nil
        )
    }
}
