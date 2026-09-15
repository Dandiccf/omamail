import QtQuick 2.15
import QtTest 1.3
import "../../calendar" as Omamail

Item {
  width: 400
  height: 300

  QtObject {
    id: mailService

    property var requests: []
    property var nextResult: ({ body: "{}", status: 200 })
    property var nextError: null
    property bool backendCanDiscoverCalendars: true
    property var discoveryCallback: null
    property var credentialWrites: []
    property var configWrites: []
    property var configCallback: null
    property var backend: ({ ready: false, call: function(method, params, callback) {
      mailService.requests.push({ method: method, params: params })
      if (method === "calendar.discover") {
        mailService.discoveryCallback = callback
        return
      }
      callback(mailService.nextResult, mailService.nextError)
    } })
    property bool unifiedCalendarView: false
    property var accountSummaries: [
      { id: "imap:work@example.com", email: "work@example.com",
        provider: "imap", signedIn: true },
      { id: "one@gmail.com", email: "one@gmail.com",
        provider: "gmail", signedIn: true },
      { id: "two@gmail.com", email: "two@gmail.com",
        provider: "gmail", signedIn: true }
    ]

    function withGoogleAccessToken(_accountId, callback) {
      callback("", "not used by this test")
    }
    function credentialPut(kind, accountId, clientId, secret, callback) {
      credentialWrites.push({kind:kind,accountId:accountId,clientId:clientId,secret:secret})
      callback(true, "")
      return true
    }
    function writeConfig(name, payload, callback) {
      configWrites.push({name:name, payload:payload})
      configCallback = callback
    }
  }

  Omamail.CalendarController {
    id: controller
    service: mailService
    pluginDir: "/tmp/omamail-test"
    accountId: "imap:work@example.com"
    sourceList: ({
      version: 1,
      sources: [{
        id: "caldav:team", kind: "caldav", name: "Team",
        url: "https://calendar.example/team/", username: "work@example.com",
        enabled: true, readOnly: false, colorKey: "accent"
      }]
    })
  }

  TestCase {
    name: "CalendarController"
    SignalSpy { id: discoverySpy; target: controller; signalName: "discoveryFinished" }

    function init() {
      // Reset here rather than at the end of each case: a failed compare aborts
      // the function, so a restore on its last line does not run and one real
      // failure becomes a cascade that hides it.
      mailService.requests = []
      mailService.nextResult = ({ body: "{}", status: 200 })
      mailService.nextError = null
      mailService.backendCanDiscoverCalendars = true
      mailService.discoveryCallback = null
      mailService.backend.ready = false
      mailService.accountSummaries = [
        { id: "imap:work@example.com", email: "work@example.com",
          provider: "imap", signedIn: true },
        { id: "one@gmail.com", email: "one@gmail.com",
          provider: "gmail", signedIn: true },
        { id: "two@gmail.com", email: "two@gmail.com",
          provider: "gmail", signedIn: true }
      ]
      mailService.credentialWrites = []
      mailService.configWrites = []
      mailService.configCallback = null
      discoverySpy.clear()
      mailService.unifiedCalendarView = false
      controller.accountId = "imap:work@example.com"
      controller.refreshScope = ""
      controller.refreshAccountId = ""
      controller.loading = false
      controller.rangeStart = 0
      controller.rangeEnd = 0
      controller.pendingRangeStart = 0
      controller.pendingRangeEnd = 0
      controller.savingSource = false
      controller.sourceBeingSaved = null
      controller.sourceSecret = ""
      controller.discoveringCalendars = false
      controller.discoveringAccountId = ""
      controller.discoverySaving = false
      controller.discoveryPendingCount = 0
      controller.discoveryError = ""
      controller.refreshAfterSourceWrite = false
      controller.sourceList = ({version:1, sources:[{
        id:"caldav:team", kind:"caldav", name:"Team",
        url:"https://calendar.example/team/", username:"work@example.com",
        enabled:true, readOnly:false, colorKey:"accent"
      }]})
    }

    function test_discovery_persists_through_platform_settings_data() {
      return [{tag:"saved", ok:true}, {tag:"failed", ok:false}]
    }

    function test_discovery_persists_through_platform_settings(data) {
      var before = JSON.stringify(controller.sourceList)
      mailService.accountSummaries = [{id:"outlook:work@example.com",
        calendarProvider:"microsoft", signedIn:true}]
      mailService.backend.ready = true
      verify(controller.discoverAccountCalendars("outlook:work@example.com"))
      mailService.discoveryCallback({provider:"microsoft", accountId:"outlook:work@example.com",
        calendars:[{sourceId:"microsoft:work", calendarId:"work", name:"Work", readOnly:false}]}, null)
      compare(mailService.configWrites.length, 1)
      compare(mailService.configWrites[0].name, "calendars.json")
      compare(JSON.parse(mailService.configWrites[0].payload).sources.length, 2)
      compare(JSON.stringify(controller.sourceList), before, "no optimistic replacement before persistence")
      compare(controller.savingSource, true)
      compare(controller.discoverySaving, true)
      compare(discoverySpy.count, 0)
      controller.setSourceEnabled("caldav:team", false)
      compare(mailService.configWrites.length, 1, "no concurrent writer while saving discovery")
      mailService.configCallback(data.ok, data.ok ? "" : "synthetic write refusal")
      compare(controller.savingSource, false)
      compare(controller.discoverySaving, false)
      compare(controller.discoveryPendingCount, 0)
      compare(controller.refreshAfterSourceWrite, false)
      compare(discoverySpy.count, 1)
      compare(Array.prototype.slice.call(discoverySpy.signalArguments[0]), data.ok ? [true, "", 1]
        : [false, "The discovered calendars could not be saved", 0])
      compare(mailService.credentialWrites.length, 0, "discovery never writes a credential")
      if (data.ok) compare(controller.sourceList.sources.length, 2)
      else compare(JSON.stringify(controller.sourceList), before)
    }

    function test_network_requests_are_owned_by_backend() {
      var source = {kind: "google", accountId: "one@gmail.com", id: "google:one@gmail.com"}
      var called = false
      controller.nativeRequest(source, "list", {start: "a", end: "b"}, function(result, error) {
        compare(error, "")
        compare(result.body, "{}")
        called = true
      })
      verify(called)
      compare(mailService.requests.length, 1)
      compare(mailService.requests[0].method, "calendar.request")
      compare(mailService.requests[0].params.source.accountId, "one@gmail.com")
      verify(mailService.requests[0].params.token === undefined)
    }

    function test_z_icloud_requests_and_discovery_never_carry_credentials() {
      var source = {kind: "icloud", accountId: "imap:person@icloud.com",
        id: "icloud:one", url: "https://p37-caldav.icloud.com/123/calendars/one/"}
      controller.nativeRequest(source, "list", {start: "a", end: "b", body: "report"},
        function(_result, error) { compare(error, "") })
      compare(mailService.requests.length, 1)
      compare(mailService.requests[0].method, "calendar.request")
      compare(mailService.requests[0].params.source.accountId, "imap:person@icloud.com")
      verify(mailService.requests[0].params.password === undefined)
      verify(mailService.requests[0].params.credentials === undefined)

      mailService.accountSummaries = [{ id: "imap:person@icloud.com",
        email: "person@icloud.com", provider: "imap", calendarProvider: "icloud",
        signedIn: true }]
      mailService.backend.ready = true
      verify(controller.discoverAccountCalendars("imap:person@icloud.com"))
      compare(mailService.requests.length, 2)
      compare(mailService.requests[1].method, "calendar.discover")
      compare(JSON.stringify(mailService.requests[1].params),
        JSON.stringify({accountId: "imap:person@icloud.com"}))
      verify(mailService.discoveryCallback !== null)
      controller.setSourceEnabled("caldav:team", false)
      compare(controller.savingSource, false,
        "calendar settings cannot race the discovery result writer")
      mailService.discoveryCallback(null, {code: -32000, message: "calendar_auth_refused"})
      compare(controller.discoveringCalendars, false)
      compare(controller.discoveryError, "Sign in to this mailbox again")

      verify(controller.discoverAccountCalendars("imap:person@icloud.com"))
      mailService.accountSummaries = []
      mailService.discoveryCallback({ provider: "icloud",
        accountId: "imap:person@icloud.com", calendars: [] }, null)
      compare(controller.savingSource, false)
      compare(controller.discoveryError, "Calendars could not be discovered")
    }

    function test_discovery_failure_uses_only_known_rpc_messages() {
      var cases = [
        {message: "auth_signed_out", expected: "Sign in to this mailbox again"},
        {message: "calendar_auth_refused", expected: "Sign in to this mailbox again"},
        {message: "calendar_provider_unsupported", expected: "This mailbox does not provide iCloud or Microsoft calendars"},
        {message: "calendar_timeout", expected: "Calendar discovery timed out"},
        {message: "private diagnostic <img src='https://example.org/tracker'>", expected: "Calendars could not be discovered"}
      ]
      for (var i = 0; i < cases.length; i++) {
        compare(controller.discoveryFailure({code: -32000, message: cases[i].message}), cases[i].expected)
      }
      compare(controller.discoveryFailure(null), "Calendars could not be discovered")
    }

    function test_discovery_on_an_old_backend_makes_no_request_or_settings_write() {
      mailService.accountSummaries = [{ id: "imap:person@icloud.com",
        calendarProvider: "icloud", signedIn: true }]
      mailService.backend.ready = true
      mailService.backendCanDiscoverCalendars = false
      compare(controller.discoverAccountCalendars("imap:person@icloud.com"), false)
      compare(mailService.requests.length, 0)
      compare(mailService.configWrites.length, 0)
      compare(mailService.credentialWrites.length, 0)
      compare(controller.savingSource, false)
      compare(controller.discoveringCalendars, false)
    }
    function test_old_backend_never_reads_or_writes_a_discovered_calendar_as_default() {
      mailService.backendCanDiscoverCalendars = false
      var sources = [{kind: "microsoft", calendarId: "other-calendar"}, {kind: "icloud"}]
      var operations = ["list", "create", "update", "delete"]
      var replies = 0
      for (var s = 0; s < sources.length; s++) {
        for (var op = 0; op < operations.length; op++) {
          controller.nativeRequest(sources[s], operations[op], {}, function(result, error) {
            compare(result, null)
            compare(error, "Update the backend to access this calendar")
            replies++
          })
        }
      }
      compare(replies, 8)
      compare(mailService.requests.length, 0)
      controller.nativeRequest({kind: "microsoft", calendarId: ""}, "list", {}, function() {})
      compare(mailService.requests.length, 1, "the established default calendar still works")
    }

    function test_native_request_explains_microsoft_recovery() {
      mailService.nextResult = null
      mailService.nextError = ({ code: -32000, message: "calendar_auth_refused" })
      var called = false
      controller.nativeRequest({ kind: "microsoft" }, "list", {}, function(result, error) {
        compare(result, null)
        compare(error, "Microsoft calendar request failed. Check Graph permissions in Settings, then sign in again")
        called = true
      })
      verify(called)
    }

    function test_native_request_does_not_display_backend_diagnostics() {
      mailService.nextResult = null
      mailService.nextError = ({ code: -32000, message: "private backend diagnostic" })
      var called = false
      controller.nativeRequest({ kind: "microsoft" }, "list", {}, function(_result, error) {
        compare(error, "Microsoft calendar request failed. Check Graph permissions in Settings, then sign in again")
        called = true
      })
      verify(called)
    }

    function sourceIds(list) {
      return list.sources.map(function(source) { return source.id })
    }

    function test_calendar_follows_the_active_mailbox_by_default() {
      var expected = ["caldav:team"]
      compare(JSON.stringify(sourceIds(controller.contextSources)),
        JSON.stringify(expected))
      compare(JSON.stringify(sourceIds(controller.sourcesForAccount(controller.accountId))),
        JSON.stringify(expected))
    }

    function test_unified_calendar_combines_every_signed_in_account() {
      mailService.unifiedCalendarView = true
      var expected = ["caldav:team", "google:one@gmail.com", "google:two@gmail.com"]
      compare(JSON.stringify(sourceIds(controller.contextSources)),
        JSON.stringify(expected))
      compare(JSON.stringify(sourceIds(controller.sourcesForAccount(controller.accountId))),
        JSON.stringify(expected))
    }

    // The cache is keyed by what the visible calendar depends on. Under the
    // unified view that is not the mailbox — the same calendars are shown
    // whichever one is open — so keying by the account stored a copy of the
    // same events per account and made every mailbox switch a cache miss.
    function test_the_scope_is_the_mailbox_only_when_the_view_follows_it() {
      compare(controller.calendarScope, "imap:work@example.com")
      mailService.unifiedCalendarView = true
      compare(controller.calendarScope, "__unified__")
      controller.accountId = "one@gmail.com"
      compare(controller.calendarScope, "__unified__",
        "and it does not move when the mailbox does")
    }

    // An answer that is still correct is not thrown away. Under the unified
    // view a refresh started while one mailbox was open is still an answer
    // about the same calendars after switching to another.
    function test_a_mailbox_switch_does_not_discard_a_unified_refresh() {
      mailService.unifiedCalendarView = true
      controller.rangeStart = 1000
      controller.rangeEnd = 2000
      controller.refreshScope = controller.calendarScope
      controller.accountId = "two@gmail.com"
      compare(controller.refreshScope, controller.calendarScope,
        "the fetch in flight still belongs to the view on screen")
    }

    // And the default mode is unchanged: there the scope is the account, so a
    // switch does invalidate what was in flight.
    function test_the_default_mode_still_follows_the_mailbox() {
      controller.rangeStart = 1000
      controller.rangeEnd = 2000
      controller.refreshScope = controller.calendarScope
      controller.accountId = "one@gmail.com"
      verify(controller.refreshScope !== controller.calendarScope)
    }

    // A controller with no mailbox is already showing every source, so the
    // setting cannot change what it shows — and renaming its scope would
    // orphan the bar preview's cache entry and refetch every calendar.
    function test_a_controller_with_no_mailbox_keeps_its_scope() {
      controller.accountId = ""
      compare(controller.calendarScope, "")
      mailService.unifiedCalendarView = true
      compare(controller.calendarScope, "", "the bar preview was always unified")
    }

    function test_changing_calendar_scope_reloads_the_visible_range() {
      controller.rangeStart = 1000
      controller.rangeEnd = 2000
      controller.loading = true

      mailService.unifiedCalendarView = true

      compare(controller.pendingRangeStart, 1000)
      compare(controller.pendingRangeEnd, 2000)
    }

    function test_updating_a_caldav_password_refreshes_the_visible_range() {
      controller.rangeStart = 1000
      controller.rangeEnd = 2000
      controller.loading = true
      controller.updateCalendarPassword(controller.sourceList.sources[0], "new-secret")
      compare(mailService.credentialWrites, [{kind:"calendar-password",
        accountId:"caldav:team",clientId:"",secret:"new-secret"}])
      compare(controller.pendingRangeStart, 1000)
      compare(controller.pendingRangeEnd, 2000)
    }
  }
}
