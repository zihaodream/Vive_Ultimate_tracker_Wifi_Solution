#pragma once

#include "openvr_driver.h"
#include "udp_pose_receiver.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>
#include <thread>

struct UtkWifiTrackerTuning
{
	bool prediction_enabled = false;
	bool smoothing_enabled = true;
	bool status_hysteresis_enabled = true;
	bool hold_uses_last_raw_valid_pose = true;
	bool require_status2_for_recovery = true;
	double position_prediction_max_seconds = 0.035;
	double rotation_prediction_max_seconds = 0.035;
	double prediction_deadband_seconds = 0.004;
	double max_prediction_velocity_mps = 8.0;
	double max_prediction_angular_velocity_radps = 20.0;
	double position_filter_min_alpha = 0.35;
	double position_filter_max_alpha = 0.92;
	double position_filter_velocity_scale = 1.6;
	double rotation_filter_min_alpha = 0.45;
	double rotation_filter_max_alpha = 0.95;
	double rotation_filter_angular_scale = 5.0;
	double hold_timeout_seconds = 0.060;
	uint32_t valid_enter_frames = 2;
	uint32_t recovery_enter_frames = 4;
	uint32_t invalid_enter_frames = 12;
	bool status4_requires_motion = true;
	double status4_motion_epsilon_mps = 0.050;
	double status4_position_epsilon_m = 0.002;
	double valid_pose_max_age_seconds = 0.100;
	double estimated_pose_time_max_age_seconds = 0.050;
	double pose_time_offset_min_seconds = -0.02;
	double pose_time_offset_max_seconds = 0.05;
};

enum class UtkWifiTrackingState
{
	Invalid,
	Recovering,
	Valid,
	Hold,
};

class UtkWifiTrackerDevice : public vr::ITrackedDeviceServerDriver
{
public:
	UtkWifiTrackerDevice(
		UdpPoseReceiver *receiver, double stale_timeout_seconds, UtkWifiTrackerTuning tuning, std::string serial_number );

	vr::EVRInitError Activate( uint32_t object_id ) override;
	void Deactivate() override;
	void EnterStandby() override;
	void *GetComponent( const char *component_name_and_version ) override;
	void DebugRequest( const char *request, char *response_buffer, uint32_t response_buffer_size ) override;
	vr::DriverPose_t GetPose() override;

	const std::string &SerialNumber() const;

private:
	void PoseUpdateThread();
	bool PoseIsFreshAndValid( const UtkWifiPose &pose ) const;
	bool Status4LooksOpticalLost( const UtkWifiPose &pose ) const;
	bool PoseIsFreshEnoughForHold( const UtkWifiPose &pose ) const;
	bool UpdateTrackingHysteresis( const UtkWifiPose &pose, bool raw_pose_valid );
	const char *TrackingStateName() const;
	void RememberRawValidPose( const UtkWifiPose &pose );
	void ApplyPoseConditioner( uint64_t received_count, const UtkWifiPose &pose, double position[3], double *qx, double *qy, double *qz, double *qw );

	UdpPoseReceiver *receiver_ = nullptr;
	double stale_timeout_seconds_ = 2.0;
	UtkWifiTrackerTuning tuning_;
	std::atomic<bool> active_{ false };
	std::thread pose_thread_;
	vr::TrackedDeviceIndex_t device_index_ = vr::k_unTrackedDeviceIndexInvalid;
	std::string serial_number_;
	bool has_reported_pose_state_ = false;
	bool last_pose_valid_ = false;
	bool tracking_valid_ = false;
	bool has_had_valid_tracking_ = false;
	UtkWifiTrackingState tracking_state_ = UtkWifiTrackingState::Invalid;
	UtkWifiTrackingState last_logged_tracking_state_ = UtkWifiTrackingState::Invalid;
	uint32_t consecutive_valid_count_ = 0;
	uint32_t consecutive_invalid_count_ = 0;
	uint64_t pose_offset_log_tick_ = 0;
	uint64_t pose_telemetry_log_tick_ = 0;
	std::chrono::steady_clock::time_point last_raw_valid_at_ = std::chrono::steady_clock::time_point::min();
	bool has_last_raw_valid_pose_ = false;
	UtkWifiPose last_raw_valid_pose_;
	bool filter_initialized_ = false;
	uint64_t filter_received_count_ = 0;
	double filtered_position_[3] = { 0.0, 0.0, 0.0 };
	double filtered_qx_ = 0.0;
	double filtered_qy_ = 0.0;
	double filtered_qz_ = 0.0;
	double filtered_qw_ = 1.0;
	mutable bool has_status4_previous_position_ = false;
	mutable double status4_previous_position_[3] = { 0.0, 0.0, 0.0 };
	mutable std::chrono::steady_clock::time_point last_status4_received_at_ = std::chrono::steady_clock::time_point::min();
	mutable bool last_status4_lost_ = false;
};
