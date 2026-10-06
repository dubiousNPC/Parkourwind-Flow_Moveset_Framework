# AnimRefresh v5

Moved out of `scripts/AnimRefresh/AnimRefresh_v5.lua` so the shared file stays lean.

AnimRefresh v5 -- model-rebuild notifier

THE PROBLEM
-----------
Several things rebuild the player's animation object. Scripted animations
and VFX attached to it are dropped when that happens, so a sitting pose, a
sheathed instrument or a worn cosmetic silently vanishes. There is no "your
VFX was removed" event to hook, so every mod that attaches something to the
player has to notice for itself and re-attach.

Three causes, and all three are in scope for this service:

  * crossing the FIRST-PERSON boundary,
  * a UI mode that rebuilds the model (Rest, Travel, Training, Jail),
  * loading a save.

WHY v5 AND NOT A FIXED v4
-------------------------
v4 registered `UiModeChanged` under `engineHandlers`. It is an EVENT, so
OpenMW rejected it:

    Not supported handler 'UiModeChanged' in
    L@0x1[scripts/animrefresh/animrefresh_v4.lua]

one line per game, and v4's Rest/Travel/Training/Jail refresh -- one of the
four things v4 was written to add -- never ran in any mod shipping it. It is
moved to `eventHandlers` here.

That fix alone was not enough, and the reason is the whole point of the
versioned filename. Every mod bundles this file at ONE shared VFS path, so
only one copy exists at runtime: whichever data directory wins. A fixed v4
and an unfixed v4 are the same path, so which copy a player gets is decided
by their install order rather than by which one is correct -- and nothing in
the game says which they got. Raising the number gives the fixed copy a path
of its own, and the `>=` guard then makes it win over any older copy still
installed, in either load order.

A stale v4 left in another mod is harmless once this exists: it registers,
loses the guard, and runs inert with no subscribers. It does still log the
"Not supported handler" line until that mod is updated, so that line now
reports which mod is behind instead of a live bug.

WHAT CHANGED IN v4, AND WHY
---------------------------
v4 is a rewrite following a review by the author of Sun's Dusk, whose
p_backpacks.lua is the implementation v1 was lifted from. Every point below
was demonstrated against the real v3 file in a simulated engine before it
was changed (tools/sim.lua, tools/sim_load.lua).

1. IT WATCHED THE WRONG SIGNAL. camera.getMode() has five values, but only
   ONE boundary rebuilds anything: first person versus not. ThirdPerson,
   Preview and Vanity all draw the same model. v3 fired on every hop
   between them, so auto-vanity after ~30s idle -- the exact state of a
   player sitting in a chair -- re-issued the pose and restarted it from
   frame 0. Measured: five spurious callbacks for one idle-to-vanity and
   back. v4 tracks a BOOLEAN, `firstPerson`, and fires only when it flips.

2. THE SETTLE/CONFIRM MACHINERY WAS GUESSING. v3 scheduled delivery off the
   TogglePOV key press, which happens BEFORE the mode changes, so the
   0.1s SETTLE_DELAY was a guess at how long the swap takes, and
   CONFIRM_DELAY was a second guess covering the first one being wrong.
   One press cost four callbacks. camera.getQueuedMode() returns the mode
   the camera is transitioning to, or nil when it has settled -- a real
   signal instead of two guesses. v4 fires when the boundary has flipped
   AND nothing is queued. One event, one delivery.

   With that, the TogglePOV handler is gone too. It existed to beat a 1s
   poll; the poll now runs at POLL_INTERVAL 0.1s, which is a camera-mode
   enum read ten times a second, and costs nothing measurable.

3. IT MISSED THE TWO CAUSES THAT ACTUALLY BITE IN PLAY. p_backpacks
   refreshes after Rest and Travel, and one frame after a game load. v3 did
   neither, and "you cannot change perspective from a menu" is true but
   beside the point -- the MODEL is rebuilt regardless. Both are now
   handled here rather than left to every subscriber to remember.

4. subscribe() AND unsubscribe() RE-BASELINED THE MODE. One mod
   unsubscribing mid-switch swallowed that transition for every other
   subscriber. v4 never re-baselines outside the poll, and a new subscriber
   instead gets one refresh of its own shortly after it registers -- which
   is also what makes "subscribe and forget" true after a load, whatever
   order the scripts register in.

THE CONTRACT
------------
    I.AnimRefresh.subscribe("MyMod", function(mode, previousMode)
        -- re-issue whatever you own
    end)
    I.AnimRefresh.unsubscribe("MyMod")

Your callback MUST be idempotent: REMOVE THEN ADD, every time, exactly as
p_backpacks does with removeVfx/addVfx. It can be called when nothing was
lost -- after a load, on subscribing, or on a retry -- and attaching a
second copy is your bug, not the service's.

VERIFY. A rebuild can finish AFTER the delivery, dropping what you just
attached, and no API can report that -- openmw.animation has addVfx and
removeVfx and nothing that reads back. So a second delivery is the only
cover, and whether it is wanted depends on what you attach:

    I.AnimRefresh.subscribe("MyMod", cb, { verify = true })

Pass it if re-attaching is invisible (removeVfx then addVfx). Leave it out
if a second call is visible -- re-issuing a looping POSE restarts it from
frame 0, which is why v3 delivering four times per press was a bug for
sitting mods and merely wasteful for cosmetic ones.

If you cannot tell whether the model was ready, RETURN FALSE and you will be
called again on a 0.1s timer, up to MAX_RETRIES times:

    I.AnimRefresh.subscribe("MyMod", function()
        if not animation.hasBone(self, MY_BONE) then return false end
        ...
    end)

Return false ONLY for a transient state. A bone your skeleton simply does
not have is not transient, and reporting it as not-ready earns a retry, a
log line and nothing else.

Never cache the interface. Call through `I.AnimRefresh.subscribe(...)` each
time: if an older bundled copy loaded first and this one overrode it, a
cached `local AR = I.AnimRefresh` is still talking to the dead copy.

COST WHEN IDLE
--------------
With no subscribers, onUpdate does one integer compare and returns. With
subscribers, it is one enum read every 0.1s and no timers at all until
something actually changes.

## Implementation notes

- No `pcall` around delivery. A subscriber that throws is that subscriber's bug, and the engine reports it with that mod's stack. Keys and callbacks are validated in `subscribe()` so a bad registration fails at the caller, not inside a timer.
- Delivery re-reads `subscribers[key]`, so a retry that lands after an unsubscribe calls nothing.
- `checkBoundary()` waits for `camera.getQueuedMode()` to be nil, so it fires after a switch has landed. ThirdPerson, Preview and Vanity share a model, so only the first-person boundary fires.
- The poll is the only writer of the baseline. `subscribe()` re-baselines only on 0 -> 1 subscribers, where there is no one else to swallow a transition from.
- `VERIFY_DELAY` (1.0s) is the one guess left: nothing in `openmw.animation` reads back whether a VFX is still attached, so a late rebuild cannot be detected. One second is past any rebuild observed.
- Rest, Travel, Training and Jail rebuild the model without touching the camera; the service fires when such a menu closes. Inventory, Book and Dialogue do not rebuild and are excluded, or a pose would restart every time a container opened.
- A load restarts the service from nothing, so it delivers on two timers (`LOAD_DELAYS`) because subscribers register in load order.
