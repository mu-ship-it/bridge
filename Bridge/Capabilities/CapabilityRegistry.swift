/// The one list of capabilities the app exposes. Adding a capability = one new file in this folder + one line here.
/// See docs/CAPABILITIES.md.
enum CapabilityRegistry {
    static let all: [any Capability] = [
        HealthQueryCapability(),
        LocationNowCapability(),
        DeviceInfoCapability(),
        ClipboardGetCapability(),
        ClipboardSetCapability(),
        NotifyShowCapability(),
        CalendarEventsCapability(),
        RemindersListCapability(),
        RemindersAddCapability(),
        ContactsSearchCapability(),
        PhotosRecentCapability(),
        MotionTodayCapability(),
        AgentSayCapability(),
    ]
}
