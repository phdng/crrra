"""F-23 Activator event/listener safety contracts, CraneSB 0x1C8B0/1CF4C/1D130/1D82C.

Source shape + independent models. Native CraneSB class used loose
containsString/hasPrefix: checks. This reconstruction hardens handling of
externally supplied Activator names and stale containers without changing
generated names, registration, callback ABI or biometric selection.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "sources/cranesb/CRActivator.m").read_text(encoding="utf-8")
paths = (root / "sources/common/CRPaths.h").read_text(encoding="utf-8")

listener_fmt = "com.opa334.crane.activatorlistener.SetActiveContainer|{app}|{container}|"
event_fmt = "com.opa334.crane.activatorevent.ChangedToContainer|{container}|{app}|"

assert '#define CR_ACTIVATOR_LISTENER_FMT       @"%@.SetActiveContainer|%@|%@|"' in paths
assert '#define CR_ACTIVATOR_EVENT_FMT          @"%@.ChangedToContainer|%@|%@|"' in paths
assert "static NSArray<NSString *> *CRActivatorParsedListenerName(NSString *name)" in source
assert "static NSArray<NSString *> *CRActivatorParsedEventName(NSString *name)" in source
for fmt, name, marker in (
    ("CR_ACTIVATOR_LISTENER_FMT", "CRActivatorParsedListenerName", "CR_ACTIVATOR_LISTENER_PREFIX"),
    ("CR_ACTIVATOR_EVENT_FMT", "CRActivatorParsedEventName", "CR_ACTIVATOR_EVENT_PREFIX"),
):
    start = source.index("static NSArray<NSString *> *" + name)
    end = source.index("\n}", start)
    body = source[start:end]
    assert "isKindOfClass:NSString.class" in body
    assert '[name componentsSeparatedByString:@"|"]' in body
    assert "parts.count != 4" in body
    assert "[parts[3] length] != 0" in body
    assert "![parts[1] length] || ![parts[2] length]" in body
    assert fmt in body and marker in body
    assert "[name isEqualToString:expected] ? parts : nil" in body

assert "return CRActivatorParsedListenerName(listenerName) != nil;" in source
assert "return CRActivatorParsedListenerName(listenerName)[1];" in source
assert "return CRActivatorParsedListenerName(listenerName)[2];" in source
assert "return CRActivatorParsedEventName(eventName) != nil;" in source
assert "return CRActivatorParsedEventName(eventName)[1];" in source
assert "return CRActivatorParsedEventName(eventName)[2];" in source

receive = source[
    source.index("- (void)activator:(id)activator receiveEvent:"):
    source.index("- (void)activator:(id)activator abortEvent:")]
abort = source[
    source.index("- (void)activator:(id)activator abortEvent:"):
    source.index("- (BOOL)activator:(id)activator\nreceiveUnlockingDeviceEvent:")]

for token in (
    "[self listenerNameIsSetActiveContainerListener:listenerName]",
    "[self.setActiveContainerListenersCache containsObject:listenerName]",
    "CRActivatorApplicationIsInstalled(applicationIdentifier)",
    "[manager containerIdentifiersOfApplicationWithIdentifier:applicationIdentifier]",
    "[containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]",
    "[containers containsObject:containerIdentifier]",
    "[previousContainerIdentifier isKindOfClass:NSString.class]",
    "![previousContainerIdentifier length]" if False else "!previousContainerIdentifier.length",
    '@{ @"previousContainerID": previousContainerIdentifier }',
    "usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated)",
):
    assert token in receive, token

assert receive.index("[containers containsObject:containerIdentifier]") < receive.index('[event setUserInfo:')
assert receive.index("!previousContainerIdentifier.length") < receive.index("[event setUserInfo:")

for token in (
    "[self listenerNameIsSetActiveContainerListener:listenerName]",
    "[self.setActiveContainerListenersCache containsObject:listenerName]",
    '[event userInfo][@"previousContainerID"]', 
    "[previousContainerIdentifier isKindOfClass:NSString.class]",
    "[manager containerIdentifiersOfApplicationWithIdentifier:applicationIdentifier]",
    "CRActivatorApplicationIsInstalled(applicationIdentifier)",
    "[previousContainerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]",
    "[containers containsObject:previousContainerIdentifier]",
    "setActiveContainerIdentifier:previousContainerIdentifier",
):
    assert token in abort, token

assert abort.index("[containers containsObject:previousContainerIdentifier]") < abort.index("setActiveContainerIdentifier:previousContainerIdentifier")

def parse_name(name, kind):
    if not isinstance(name, str):
        return None
    pieces = name.split("|")
    if len(pieces) != 4 or pieces[3] or not pieces[1] or not pieces[2]:
        return None
    expected = (listener_fmt if kind == "listener" else event_fmt).format(
        app=pieces[1] if kind == "listener" else pieces[2],
        container=pieces[2] if kind == "listener" else pieces[1]
    )
    return pieces[1:3] if name == expected else None

listener = listener_fmt.format(app="com.example.app", container="C1")
event = event_fmt.format(app="com.example.app", container="C1")
assert parse_name(listener, "listener") == ["com.example.app", "C1"]
assert parse_name(event, "event") == ["C1", "com.example.app"]
for bad in (
    None, "", "Other.SetActiveContainer|com.example.app|C1|",
    listener + "extra", listener[:-1], listener.replace("|C1|", "||"),
    listener + "|another", "Other.ChangedToContainer|C1|com.example.app|",
):
    assert parse_name(bad, "listener") is None, bad
for bad in (None, "", event[:-1], event + "other", event.replace("|C1|", "||"),
            "NotCrane.ChangedToContainer|C1|com.example.app|"):
    assert parse_name(bad, "event") is None, bad

def eligible(current, previous, registered, app_installed):
    return bool(current and previous and app_installed and
                (current == "DEFAULT" or current in registered))

assert eligible("C1", "DEFAULT", {"C1"}, True)
assert eligible("DEFAULT", "C1", set(), True)
assert not eligible("C2", "C1", {"C1"}, True)
assert not eligible("C1", None, {"C1"}, True)
assert not eligible("C1", "DEFAULT", {"C1"}, False)
print("Crane F-23 Activator validated event/listener contracts: PASS (runtime unverified)")
