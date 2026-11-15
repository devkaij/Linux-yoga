/*
    KWin - the KDE window manager
    This file is part of the KDE project.

    SPDX-License-Identifier: GPL-2.0-or-later
*/
#include "anland_input.h"
#include "anland_backend.h"

#include <chrono>
#include <linux/input.h>

namespace KWin
{

/* Native stylus tool descriptor. Ported from SuperTurtleDev/anland legacy 5.23
 * anland_input.cpp: KWin keys tablet seats by tool object identity, so one
 * TabletTool per wire tool_id, with the identity fields it exposes to clients. */
class AnlandInputDevice::TabletTool final : public InputDeviceTabletTool
{
public:
    TabletTool(const anland_tablet_sample &sample, QObject *parent)
        : InputDeviceTabletTool(parent)
        , m_serialId(sample.tool_id)
        , m_uniqueId(sample.device_id)
        , m_type(sample.tool_type == TABLET_TOOL_ERASER ? Eraser : Pen)
        , m_protocolCapabilities(sample.capabilities)
    {
        if (sample.capabilities & TABLET_CAP_PRESSURE) {
            m_capabilities.append(Pressure);
        }
        if (sample.capabilities & TABLET_CAP_TILT) {
            m_capabilities.append(Tilt);
        }
        if (sample.capabilities & TABLET_CAP_DISTANCE) {
            m_capabilities.append(Distance);
        }
    }

    quint64 serialId() const override
    {
        return m_serialId;
    }
    quint64 uniqueId() const override
    {
        return m_uniqueId;
    }
    Type type() const override
    {
        return m_type;
    }
    QList<Capability> capabilities() const override
    {
        return m_capabilities;
    }
    bool matches(const anland_tablet_sample &sample) const
    {
        return m_serialId == sample.tool_id && m_uniqueId == sample.device_id
            && m_protocolCapabilities == sample.capabilities
            && m_type == (sample.tool_type == TABLET_TOOL_ERASER ? Eraser : Pen);
    }

private:
    quint64 m_serialId;
    quint64 m_uniqueId;
    Type m_type;
    uint32_t m_protocolCapabilities;
    QList<Capability> m_capabilities;
};

static std::chrono::microseconds now()
{
    return std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch());
}

AnlandInputDevice::AnlandInputDevice(QObject *parent)
    : InputDevice(parent)
{
}

QString AnlandInputDevice::name() const
{
    return QStringLiteral("anland virtual input");
}

bool AnlandInputDevice::isEnabled() const
{
    return m_enabled;
}

void AnlandInputDevice::setEnabled(bool enabled)
{
    m_enabled = enabled;
}

LEDs AnlandInputDevice::leds() const
{
    return LEDs();
}

void AnlandInputDevice::setLeds(LEDs leds)
{
}

bool AnlandInputDevice::isKeyboard() const
{
    return true;
}

bool AnlandInputDevice::isPointer() const
{
    return true;
}

bool AnlandInputDevice::isTouchpad() const
{
    return false;
}

bool AnlandInputDevice::isTouch() const
{
    return true;
}

bool AnlandInputDevice::isTabletTool() const
{
    return true;
}

bool AnlandInputDevice::isTabletPad() const
{
    return false;
}

bool AnlandInputDevice::isTabletModeSwitch() const
{
    return false;
}

bool AnlandInputDevice::isLidSwitch() const
{
    return false;
}

// KWin only delivers pointer events to client apps on a wl_pointer.frame, so every
// pointer event must be followed by a pointerFrame() (exactly as the libinput
// backend does). Without it scroll is dropped entirely; cursor motion and focus
// still appear to work only because PointerInputRedirection handles those
// compositor-side, independent of client delivery.
void AnlandInputDevice::pointerMotionAbsolute(const QPointF &position)
{
    Q_EMIT InputDevice::pointerMotionAbsolute(position, now(), this);
    Q_EMIT InputDevice::pointerFrame(this);
}

void AnlandInputDevice::pointerMotion(const QPointF &pos, const QPointF &delta, const QPointF &deltaUnaccel)
{
    Q_EMIT InputDevice::pointerMotionAbsolute(pos, now(), this);
    Q_EMIT InputDevice::pointerMotion(delta, deltaUnaccel, now(), this);
    Q_EMIT InputDevice::pointerFrame(this);
}

void AnlandInputDevice::pointerButton(quint32 button, bool pressed)
{
    Q_EMIT pointerButtonChanged(button,
                                pressed ? PointerButtonState::Pressed : PointerButtonState::Released,
                                now(), this);
    Q_EMIT InputDevice::pointerFrame(this);
}

void AnlandInputDevice::pointerAxis(PointerAxis axis, qreal delta, qint32 deltaV120)
{
    const PointerAxisSource source =
        deltaV120 != 0 ? PointerAxisSource::Wheel : PointerAxisSource::Continuous;
    // 6.x pointerAxisChanged carries an explicit "inverted" (natural scroll) flag;
    // the daemon already delivers deltas in KWin's direction, so it is never set.
    Q_EMIT pointerAxisChanged(axis, delta, deltaV120, source, false, now(), this);
    Q_EMIT InputDevice::pointerFrame(this);
}

void AnlandInputDevice::keyboardKey(quint32 keycode, bool pressed)
{
    Q_EMIT keyChanged(keycode,
                      pressed ? KeyboardKeyState::Pressed : KeyboardKeyState::Released,
                      now(), this);
}

void AnlandInputDevice::touchDown(qint32 id, const QPointF &position)
{
    Q_EMIT InputDevice::touchDown(id, position, now(), this);
}

void AnlandInputDevice::touchMotion(qint32 id, const QPointF &position)
{
    Q_EMIT InputDevice::touchMotion(id, position, now(), this);
}

void AnlandInputDevice::touchUp(qint32 id)
{
    Q_EMIT InputDevice::touchUp(id, now(), this);
}

void AnlandInputDevice::touchFrame()
{
    Q_EMIT InputDevice::touchFrame(this);
}

void AnlandInputDevice::touchCancel()
{
    Q_EMIT touchCanceled(this);
}

AnlandInputDevice::TabletTool *AnlandInputDevice::tabletTool(const anland_tablet_sample &sample)
{
    TabletTool *tool = m_tabletTools.value(sample.tool_id, nullptr);
    if (tool && !tool->matches(sample)) {
        // KWin's tablet seat keys tools by object identity and keeps a Wayland
        // tool alive after proximity-out, so a recycled wire id must not steal
        // the previous object's identity. Keep the old one alive.
        tool = nullptr;
    }
    if (!tool) {
        tool = new TabletTool(sample, this);
        m_tabletTools.insert(sample.tool_id, tool);
    }
    return tool;
}

void AnlandInputDevice::tabletFrame(const anland_tablet_sample &previous,
                                    const anland_tablet_sample &sample,
                                    const QPointF &position)
{
    TabletTool *tool = tabletTool(sample);
    const bool wasNear = previous.flags & TABLET_FLAG_PROXIMITY;
    const bool isNear = (sample.flags & TABLET_FLAG_PROXIMITY) && !(sample.flags & TABLET_FLAG_CANCELED);
    const bool wasDown = previous.flags & TABLET_FLAG_TIP_DOWN;
    const bool isDown = isNear && (sample.flags & TABLET_FLAG_TIP_DOWN);
    const quint32 oldButtons = previous.buttons;
    const quint32 newButtons = isNear ? sample.buttons : 0;
    const auto timestamp = std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::milliseconds(sample.time_msec));

    if (!wasNear && isNear) {
        Q_EMIT tabletToolProximityEvent(position, sample.pressure, sample.tilt_x, sample.tilt_y,
                                        0, sample.distance, isDown, true, tool, timestamp, this);
    }

    // Match libinput ordering: a tip-down carries its axes first; a tip-up
    // releases before the post-release axis sample arrives.
    if (wasDown && !isDown) {
        Q_EMIT tabletToolTipEvent(position, sample.pressure, sample.tilt_x, sample.tilt_y,
                                  0, sample.distance, false, isNear, tool, timestamp, this);
    }
    if (isNear) {
        Q_EMIT tabletToolAxisEvent(position, sample.pressure, sample.tilt_x, sample.tilt_y,
                                   0, sample.distance, isDown, isNear, tool, timestamp, this);
    }
    if (!wasDown && isDown) {
        Q_EMIT tabletToolTipEvent(position, sample.pressure, sample.tilt_x, sample.tilt_y,
                                  0, sample.distance, true, isNear, tool, timestamp, this);
    }

    if ((oldButtons & TABLET_BUTTON_PRIMARY) != (newButtons & TABLET_BUTTON_PRIMARY)) {
        Q_EMIT tabletToolButtonEvent(BTN_STYLUS, newButtons & TABLET_BUTTON_PRIMARY, tool, timestamp, this);
    }
    if ((oldButtons & TABLET_BUTTON_SECONDARY) != (newButtons & TABLET_BUTTON_SECONDARY)) {
        Q_EMIT tabletToolButtonEvent(BTN_STYLUS2, newButtons & TABLET_BUTTON_SECONDARY, tool, timestamp, this);
    }

    if (wasNear && !isNear) {
        Q_EMIT tabletToolProximityEvent(position, previous.pressure, previous.tilt_x, previous.tilt_y,
                                        0, previous.distance, false, false, tool, timestamp, this);
    }
}

AnlandInputBackend::AnlandInputBackend(AnlandBackend *backend)
    : m_backend(backend)
{
}

void AnlandInputBackend::initialize()
{
    if (AnlandInputDevice *device = m_backend->inputDevice()) {
        Q_EMIT deviceAdded(device);
    }
}

} // namespace KWin

#include "moc_anland_input.cpp"
