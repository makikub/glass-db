import Testing
@testable import GlassDB

@Suite
struct PostgreSQLDriverTests {
    @Test
    func quotesIdentifiersAndRejectsInjectionFragments() {
        let driver = PostgreSQLDriver()
        #expect(driver.quoteIdentifier("simple") == "\"simple\"")
        #expect(driver.quoteIdentifier("odd\"name") == "\"odd\"\"name\"")
        #expect(PostgreSQLDriver.isReadOnlyQuery("SELECT * FROM projects"))
        #expect(PostgreSQLDriver.isReadOnlyQuery("-- inspect\n SELECT 1;"))
        #expect(!PostgreSQLDriver.isReadOnlyQuery("DELETE FROM projects"))
        #expect(!PostgreSQLDriver.isReadOnlyQuery("SELECT 1; DELETE FROM projects"))
        #expect(!PostgreSQLDriver.isReadOnlyQuery("WITH deleted AS (DELETE FROM projects RETURNING *) SELECT * FROM deleted"))
    }

    @Test
    func appliesAutomaticLimitWithoutLeavingTrailingSemicolon() {
        #expect(PostgreSQLDriver.limitedSQL("SELECT id FROM projects;", limit: 25) == "SELECT id FROM projects LIMIT 25")
        #expect(PostgreSQLDriver.limitedSQL("SELECT id FROM projects LIMIT 5", limit: 25) == "SELECT id FROM projects LIMIT 5")
        #expect(PostgreSQLDriver.limitedSQL("select id from projects limit 5", limit: 25) == "select id from projects limit 5")
        #expect(PostgreSQLDriver.limitedSQL("SeLeCt id FrOm projects LiMiT 5", limit: 25) == "SeLeCt id FrOm projects LiMiT 5")
        #expect(PostgreSQLDriver.limitedSQL("SELECT id\nFROM projects\nLIMIT 5", limit: 25) == "SELECT id\nFROM projects\nLIMIT 5")
    }

    @Test
    func disambiguatesDuplicateResultColumnNames() {
        #expect(PostgreSQLDriver.uniqueColumnNames(["id", "id", "name", "id", "name"]) == [
            "id", "id_2", "name", "id_3", "name_2",
        ])
        #expect(PostgreSQLDriver.uniqueColumnNames(["id", "id_2", "id"]) == ["id", "id_2", "id_3"])
    }

    @Test
    func executePreservesSQLWorkspaceReadOnlyBoundary() async {
        let driver = PostgreSQLDriver()
        do {
            _ = try await driver.execute("UPDATE projects SET status = 'deleted'")
            Issue.record("PostgreSQL execute unexpectedly allowed a write")
        } catch let error as DatabaseError {
            #expect(error.errorDescription == "This PostgreSQL connection is read-only. Only SELECT queries are allowed.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
