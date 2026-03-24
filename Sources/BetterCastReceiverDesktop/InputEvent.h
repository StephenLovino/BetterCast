#pragma once

#include <cstdint>
#include <QJsonObject>
#include <QJsonDocument>
#include <QByteArray>
#include <atomic>

// Matches Swift InputEventType exactly
enum class InputEventType : int {
    MouseMove = 0,
    LeftMouseDown = 1,
    LeftMouseUp = 2,
    RightMouseDown = 3,
    RightMouseUp = 4,
    KeyDown = 5,
    KeyUp = 6,
    ScrollWheel = 7,
    Command = 99
};

// Special command keyCodes
constexpr uint16_t kHeartbeatKeyCode = 888;
constexpr uint16_t kIDRRequestKeyCode = 999;

struct InputEvent {
    InputEventType type;
    double x = 0.0;       // Normalized 0-1
    double y = 0.0;       // Normalized 0-1
    uint16_t keyCode = 0;
    double deltaX = 0.0;
    double deltaY = 0.0;
    uint64_t eventId = 0;

    InputEvent() : type(InputEventType::MouseMove) {
        eventId = nextId();
    }

    InputEvent(InputEventType type, double x = 0.0, double y = 0.0,
               uint16_t keyCode = 0, double deltaX = 0.0, double deltaY = 0.0)
        : type(type), x(x), y(y), keyCode(keyCode), deltaX(deltaX), deltaY(deltaY)
    {
        eventId = nextId();
    }

    QByteArray toJson() const {
        QJsonObject obj;
        obj["type"] = static_cast<int>(type);
        obj["x"] = x;
        obj["y"] = y;
        obj["keyCode"] = keyCode;
        obj["deltaX"] = deltaX;
        obj["deltaY"] = deltaY;
        obj["eventId"] = static_cast<qint64>(eventId);
        return QJsonDocument(obj).toJson(QJsonDocument::Compact);
    }

    // Length-prefixed packet ready to send over TCP
    QByteArray toPacket() const {
        QByteArray json = toJson();
        uint32_t len = qToBigEndian(static_cast<uint32_t>(json.size()));
        QByteArray packet;
        packet.append(reinterpret_cast<const char*>(&len), 4);
        packet.append(json);
        return packet;
    }

private:
    static uint64_t nextId() {
        static std::atomic<uint64_t> counter{0};
        return ++counter;
    }
};
