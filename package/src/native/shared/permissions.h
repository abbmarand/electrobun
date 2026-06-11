// permissions.h - Cross-platform permission cache management
// Used for caching permission responses across Windows, macOS, and Linux.
//
// This is a header-only implementation to avoid build complexity.

#ifndef ELECTROBUN_PERMISSIONS_H
#define ELECTROBUN_PERMISSIONS_H

#include <chrono>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace electrobun {

enum class PermissionType {
    USER_MEDIA,
    GEOLOCATION,
    NOTIFICATIONS,
    CAMERA,
    MICROPHONE,
    MIDI,
    CLIPBOARD_READ,
    CLIPBOARD_WRITE,
    SCREEN,
    MIDI_SYSEX,
    TOP_LEVEL_STORAGE_ACCESS,
    STORAGE_ACCESS,
    DISK_QUOTA,
    LOCAL_FONTS,
    HAND_TRACKING,
    IDENTITY_PROVIDER,
    IDLE_DETECTION,
    MULTIPLE_DOWNLOADS,
    KEYBOARD_LOCK,
    POINTER_LOCK,
    PROTECTED_MEDIA_IDENTIFIER,
    REGISTER_PROTOCOL_HANDLER,
    VR_SESSION,
    WEB_APP_INSTALLATION,
    WINDOW_MANAGEMENT,
    FILE_SYSTEM_ACCESS,
    LOCAL_NETWORK,
    LOOPBACK_NETWORK,
    AR_SESSION,
    SENSORS,
    LOCAL_NETWORK_ACCESS,
    OTHER
};

enum class PermissionStatus {
    UNKNOWN,
    ALLOWED,
    DENIED
};

struct PermissionCacheEntry {
    PermissionStatus status;
    std::chrono::system_clock::time_point expiry;
};

// Thread-safe permission cache
class PermissionCache {
public:
    static PermissionCache& getInstance() {
        static PermissionCache instance;
        return instance;
    }

    // Extract origin from a URL (e.g., "https://example.com/path" -> "https://example.com")
    static std::string getOriginFromUrl(const std::string& url) {
        // For views:// scheme, use a constant origin since these are local files
        if (url.find("views://") == 0) {
            return "views://";
        }

        // For other schemes, extract origin from URL
        size_t protocolEnd = url.find("://");
        if (protocolEnd == std::string::npos) return url;

        size_t domainStart = protocolEnd + 3;
        size_t pathStart = url.find('/', domainStart);

        if (pathStart == std::string::npos) {
            return url;
        }

        return url.substr(0, pathStart);
    }

    PermissionStatus get(const std::string& origin, PermissionType type) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto key = std::make_pair(origin, type);
        auto it = cache_.find(key);

        if (it != cache_.end()) {
            // Check if permission hasn't expired
            auto now = std::chrono::system_clock::now();
            if (now < it->second.expiry) {
                return it->second.status;
            }

            // Permission expired, remove from cache
            cache_.erase(it);
        }

        return PermissionStatus::UNKNOWN;
    }

    void set(const std::string& origin, PermissionType type, PermissionStatus status) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto key = std::make_pair(origin, type);

        // Cache permission for 24 hours
        auto expiry = std::chrono::system_clock::now() + std::chrono::hours(24);
        cache_[key] = {status, expiry};
    }

private:
    PermissionCache() = default;
    PermissionCache(const PermissionCache&) = delete;
    PermissionCache& operator=(const PermissionCache&) = delete;

    std::map<std::pair<std::string, PermissionType>, PermissionCacheEntry> cache_;
    std::mutex mutex_;
};

inline void addPermissionBucket(std::vector<PermissionType>& buckets, PermissionType type) {
    for (PermissionType existing : buckets) {
        if (existing == type) {
            return;
        }
    }
    buckets.push_back(type);
}

inline PermissionType permissionBucketForName(const std::string& permissionType) {
    if (permissionType == "camera") return PermissionType::CAMERA;
    if (permissionType == "microphone") return PermissionType::MICROPHONE;
    if (permissionType == "geolocation") return PermissionType::GEOLOCATION;
    if (permissionType == "notifications") return PermissionType::NOTIFICATIONS;
    if (permissionType == "midi") return PermissionType::MIDI;
    if (permissionType == "clipboardRead") return PermissionType::CLIPBOARD_READ;
    if (permissionType == "clipboardWrite") return PermissionType::CLIPBOARD_WRITE;
    if (permissionType == "screen") return PermissionType::SCREEN;
    if (permissionType == "midiSysex") return PermissionType::MIDI_SYSEX;
    if (permissionType == "topLevelStorageAccess") return PermissionType::TOP_LEVEL_STORAGE_ACCESS;
    if (permissionType == "storageAccess") return PermissionType::STORAGE_ACCESS;
    if (permissionType == "diskQuota") return PermissionType::DISK_QUOTA;
    if (permissionType == "localFonts") return PermissionType::LOCAL_FONTS;
    if (permissionType == "handTracking") return PermissionType::HAND_TRACKING;
    if (permissionType == "identityProvider") return PermissionType::IDENTITY_PROVIDER;
    if (permissionType == "idleDetection") return PermissionType::IDLE_DETECTION;
    if (permissionType == "multipleDownloads") return PermissionType::MULTIPLE_DOWNLOADS;
    if (permissionType == "keyboardLock") return PermissionType::KEYBOARD_LOCK;
    if (permissionType == "pointerLock") return PermissionType::POINTER_LOCK;
    if (permissionType == "protectedMediaIdentifier") return PermissionType::PROTECTED_MEDIA_IDENTIFIER;
    if (permissionType == "registerProtocolHandler") return PermissionType::REGISTER_PROTOCOL_HANDLER;
    if (permissionType == "vrSession") return PermissionType::VR_SESSION;
    if (permissionType == "webAppInstallation") return PermissionType::WEB_APP_INSTALLATION;
    if (permissionType == "windowManagement") return PermissionType::WINDOW_MANAGEMENT;
    if (permissionType == "fileSystemAccess") return PermissionType::FILE_SYSTEM_ACCESS;
    if (permissionType == "localNetwork") return PermissionType::LOCAL_NETWORK;
    if (permissionType == "loopbackNetwork") return PermissionType::LOOPBACK_NETWORK;
    if (permissionType == "arSession") return PermissionType::AR_SESSION;
    if (permissionType == "sensors") return PermissionType::SENSORS;
    if (permissionType == "localNetworkAccess") return PermissionType::LOCAL_NETWORK_ACCESS;
    return PermissionType::OTHER;
}

inline std::vector<PermissionType> permissionBucketsForPermissionTypes(const std::vector<std::string>& permissionTypes) {
    std::vector<PermissionType> buckets;
    for (const auto& permissionType : permissionTypes) {
        addPermissionBucket(buckets, permissionBucketForName(permissionType));
    }
    return buckets;
}

// Convenience functions that use the singleton (for easier migration from existing code)
inline std::string getOriginFromUrl(const std::string& url) {
    return PermissionCache::getOriginFromUrl(url);
}

inline PermissionStatus getPermissionFromCache(const std::string& origin, PermissionType type) {
    return PermissionCache::getInstance().get(origin, type);
}

inline PermissionStatus getPermissionFromCache(
    const std::string& origin,
    const std::vector<PermissionType>& permissionTypes
) {
    if (permissionTypes.empty()) {
        return PermissionStatus::UNKNOWN;
    }

    bool allAllowed = true;
    for (PermissionType type : permissionTypes) {
        PermissionStatus status = getPermissionFromCache(origin, type);
        if (status == PermissionStatus::DENIED) {
            return PermissionStatus::DENIED;
        }
        if (status != PermissionStatus::ALLOWED) {
            allAllowed = false;
        }
    }

    return allAllowed ? PermissionStatus::ALLOWED : PermissionStatus::UNKNOWN;
}

inline PermissionStatus getPermissionFromCache(const std::string& origin, const std::vector<std::string>& permissionTypes) {
    const auto buckets = permissionBucketsForPermissionTypes(permissionTypes);
    return getPermissionFromCache(origin, buckets);
}

inline void cachePermission(const std::string& origin, PermissionType type, PermissionStatus status) {
    PermissionCache::getInstance().set(origin, type, status);
}

inline void cachePermission(
    const std::string& origin,
    const std::vector<PermissionType>& permissionTypes,
    PermissionStatus status
) {
    for (PermissionType type : permissionTypes) {
        cachePermission(origin, type, status);
    }
}

inline void cachePermission(
    const std::string& origin,
    const std::vector<std::string>& permissionTypes,
    PermissionStatus status
) {
    const auto buckets = permissionBucketsForPermissionTypes(permissionTypes);
    cachePermission(origin, buckets, status);
}

} // namespace electrobun

#endif // ELECTROBUN_PERMISSIONS_H
