#pragma once

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

struct UtkWifiPose
{
	double x = 0.0;
	double y = 0.0;
	double z = 0.0;
	double qx = 0.0;
	double qy = 0.0;
	double qz = 0.0;
	double qw = 1.0;
	double vx = 0.0;
	double vy = 0.0;
	double vz = 0.0;
	double wx = 0.0;
	double wy = 0.0;
	double wz = 0.0;
	int pose_status = 3;
	uint8_t seq = 0;
	uint64_t source_time_ns = 0;
	uint64_t pc_estimated_pose_time_ns = 0;
	uint64_t device_time_ticks = 0;
	uint16_t device_time = 0;
	std::chrono::steady_clock::time_point received_at = std::chrono::steady_clock::time_point::min();
	std::chrono::steady_clock::time_point estimated_pose_at = std::chrono::steady_clock::time_point::min();
};

class UdpPoseReceiver
{
public:
	UdpPoseReceiver() = default;
	~UdpPoseReceiver();

	bool Start( const std::string &bind_host, uint16_t port );
	void Stop();
	UtkWifiPose Latest() const;
	bool IsRunning() const;
	uint64_t ReceivedCount() const;

private:
	void ThreadMain( std::string bind_host, uint16_t port );
	static bool ParsePosePacket( const char *data, size_t size, UtkWifiPose *pose );
	static bool ParsePoseBinary( const char *data, size_t size, UtkWifiPose *pose );
	static bool ParsePoseJson( const std::string &json, UtkWifiPose *pose );
	static bool ExtractDoubleNeedle( const std::string &json, const char *needle, double *value );
	static bool ExtractIntNeedle( const std::string &json, const char *needle, int *value );
	static bool ExtractUInt64Needle( const std::string &json, const char *needle, uint64_t *value );

	mutable std::mutex mutex_;
	UtkWifiPose latest_;
	std::atomic<bool> running_{ false };
	std::atomic<uint64_t> received_count_{ 0 };
	std::thread thread_;
};
