#include "device_provider.h"

#include "driverlog.h"

#include <cstdio>
#include <utility>

namespace
{
const char *kSettingsSection = "driver_utk_wifi_tracker";
const char *kUdpBindHostKey = "udp_bind_host";
const char *kUdpPortKey = "udp_port";
const char *kTrackerCountKey = "tracker_count";
const char *kStaleTimeoutSecondsKey = "stale_timeout_seconds";
const char *kPredictionEnabledKey = "prediction_enabled";
const char *kSmoothingEnabledKey = "smoothing_enabled";
const char *kStatusHysteresisEnabledKey = "status_hysteresis_enabled";
const char *kHoldUsesLastRawValidPoseKey = "hold_uses_last_raw_valid_pose";
const char *kRequireStatus2ForRecoveryKey = "require_status2_for_recovery";
const char *kPositionPredictionMaxSecondsKey = "position_prediction_max_seconds";
const char *kRotationPredictionMaxSecondsKey = "rotation_prediction_max_seconds";
const char *kPredictionDeadbandSecondsKey = "prediction_deadband_seconds";
const char *kMaxPredictionVelocityMpsKey = "max_prediction_velocity_mps";
const char *kMaxPredictionAngularVelocityRadpsKey = "max_prediction_angular_velocity_radps";
const char *kPositionFilterMinAlphaKey = "position_filter_min_alpha";
const char *kPositionFilterMaxAlphaKey = "position_filter_max_alpha";
const char *kPositionFilterVelocityScaleKey = "position_filter_velocity_scale";
const char *kRotationFilterMinAlphaKey = "rotation_filter_min_alpha";
const char *kRotationFilterMaxAlphaKey = "rotation_filter_max_alpha";
const char *kRotationFilterAngularScaleKey = "rotation_filter_angular_scale";
const char *kHoldTimeoutSecondsKey = "hold_timeout_seconds";
const char *kValidEnterFramesKey = "valid_enter_frames";
const char *kRecoveryEnterFramesKey = "recovery_enter_frames";
const char *kInvalidEnterFramesKey = "invalid_enter_frames";
const char *kStatus4RequiresMotionKey = "status4_requires_motion";
const char *kStatus4MotionEpsilonMpsKey = "status4_motion_epsilon_mps";
const char *kStatus4PositionEpsilonMKey = "status4_position_epsilon_m";
const char *kValidPoseMaxAgeSecondsKey = "valid_pose_max_age_seconds";
const char *kEstimatedPoseTimeMaxAgeSecondsKey = "estimated_pose_time_max_age_seconds";
const char *kPoseTimeOffsetMinSecondsKey = "pose_time_offset_min_seconds";
const char *kPoseTimeOffsetMaxSecondsKey = "pose_time_offset_max_seconds";

std::string GetStringSetting( const char *key, const char *fallback )
{
	char value[1024] = {};
	vr::EVRSettingsError error = vr::VRSettingsError_None;
	vr::VRSettings()->GetString( kSettingsSection, key, value, sizeof( value ), &error );
	if ( error != vr::VRSettingsError_None || value[0] == '\0' )
		return fallback;
	return value;
}

int32_t GetIntSetting( const char *key, int32_t fallback )
{
	vr::EVRSettingsError error = vr::VRSettingsError_None;
	const int32_t value = vr::VRSettings()->GetInt32( kSettingsSection, key, &error );
	return error == vr::VRSettingsError_None ? value : fallback;
}

float GetFloatSetting( const char *key, float fallback )
{
	vr::EVRSettingsError error = vr::VRSettingsError_None;
	const float value = vr::VRSettings()->GetFloat( kSettingsSection, key, &error );
	return error == vr::VRSettingsError_None ? value : fallback;
}

bool GetBoolSetting( const char *key, bool fallback )
{
	vr::EVRSettingsError error = vr::VRSettingsError_None;
	const bool value = vr::VRSettings()->GetBool( kSettingsSection, key, &error );
	return error == vr::VRSettingsError_None ? value : fallback;
}

double ClampDouble( double value, double minimum, double maximum )
{
	if ( value < minimum )
		return minimum;
	if ( value > maximum )
		return maximum;
	return value;
}

uint32_t ClampFrameCount( int32_t value, uint32_t fallback )
{
	if ( value < 1 )
		return fallback;
	if ( value > 240 )
		return 240;
	return static_cast<uint32_t>( value );
}

UtkWifiTrackerTuning LoadTrackerTuning()
{
	UtkWifiTrackerTuning tuning;
	tuning.prediction_enabled = GetBoolSetting( kPredictionEnabledKey, tuning.prediction_enabled );
	tuning.smoothing_enabled = GetBoolSetting( kSmoothingEnabledKey, tuning.smoothing_enabled );
	tuning.status_hysteresis_enabled = GetBoolSetting( kStatusHysteresisEnabledKey, tuning.status_hysteresis_enabled );
	tuning.hold_uses_last_raw_valid_pose = GetBoolSetting( kHoldUsesLastRawValidPoseKey, tuning.hold_uses_last_raw_valid_pose );
	tuning.require_status2_for_recovery = GetBoolSetting( kRequireStatus2ForRecoveryKey, tuning.require_status2_for_recovery );
	tuning.position_prediction_max_seconds =
		ClampDouble( GetFloatSetting( kPositionPredictionMaxSecondsKey, static_cast<float>( tuning.position_prediction_max_seconds ) ), 0.0, 0.25 );
	tuning.rotation_prediction_max_seconds =
		ClampDouble( GetFloatSetting( kRotationPredictionMaxSecondsKey, static_cast<float>( tuning.rotation_prediction_max_seconds ) ), 0.0, 0.25 );
	tuning.prediction_deadband_seconds =
		ClampDouble( GetFloatSetting( kPredictionDeadbandSecondsKey, static_cast<float>( tuning.prediction_deadband_seconds ) ), 0.0, 0.05 );
	tuning.max_prediction_velocity_mps =
		ClampDouble( GetFloatSetting( kMaxPredictionVelocityMpsKey, static_cast<float>( tuning.max_prediction_velocity_mps ) ), 0.0, 100.0 );
	tuning.max_prediction_angular_velocity_radps = ClampDouble(
		GetFloatSetting( kMaxPredictionAngularVelocityRadpsKey, static_cast<float>( tuning.max_prediction_angular_velocity_radps ) ), 0.0, 200.0 );
	tuning.position_filter_min_alpha =
		ClampDouble( GetFloatSetting( kPositionFilterMinAlphaKey, static_cast<float>( tuning.position_filter_min_alpha ) ), 0.0, 1.0 );
	tuning.position_filter_max_alpha =
		ClampDouble( GetFloatSetting( kPositionFilterMaxAlphaKey, static_cast<float>( tuning.position_filter_max_alpha ) ), 0.0, 1.0 );
	tuning.position_filter_velocity_scale =
		ClampDouble( GetFloatSetting( kPositionFilterVelocityScaleKey, static_cast<float>( tuning.position_filter_velocity_scale ) ), 0.001, 100.0 );
	tuning.rotation_filter_min_alpha =
		ClampDouble( GetFloatSetting( kRotationFilterMinAlphaKey, static_cast<float>( tuning.rotation_filter_min_alpha ) ), 0.0, 1.0 );
	tuning.rotation_filter_max_alpha =
		ClampDouble( GetFloatSetting( kRotationFilterMaxAlphaKey, static_cast<float>( tuning.rotation_filter_max_alpha ) ), 0.0, 1.0 );
	tuning.rotation_filter_angular_scale =
		ClampDouble( GetFloatSetting( kRotationFilterAngularScaleKey, static_cast<float>( tuning.rotation_filter_angular_scale ) ), 0.001, 200.0 );
	tuning.hold_timeout_seconds =
		ClampDouble( GetFloatSetting( kHoldTimeoutSecondsKey, static_cast<float>( tuning.hold_timeout_seconds ) ), 0.0, 2.0 );
	tuning.valid_enter_frames = ClampFrameCount( GetIntSetting( kValidEnterFramesKey, static_cast<int32_t>( tuning.valid_enter_frames ) ), tuning.valid_enter_frames );
	tuning.recovery_enter_frames =
		ClampFrameCount( GetIntSetting( kRecoveryEnterFramesKey, static_cast<int32_t>( tuning.recovery_enter_frames ) ), tuning.recovery_enter_frames );
	tuning.invalid_enter_frames =
		ClampFrameCount( GetIntSetting( kInvalidEnterFramesKey, static_cast<int32_t>( tuning.invalid_enter_frames ) ), tuning.invalid_enter_frames );
	tuning.status4_requires_motion = GetBoolSetting( kStatus4RequiresMotionKey, tuning.status4_requires_motion );
	tuning.status4_motion_epsilon_mps =
		ClampDouble( GetFloatSetting( kStatus4MotionEpsilonMpsKey, static_cast<float>( tuning.status4_motion_epsilon_mps ) ), 0.0, 2.0 );
	tuning.status4_position_epsilon_m =
		ClampDouble( GetFloatSetting( kStatus4PositionEpsilonMKey, static_cast<float>( tuning.status4_position_epsilon_m ) ), 0.0, 0.1 );
	tuning.valid_pose_max_age_seconds =
		ClampDouble( GetFloatSetting( kValidPoseMaxAgeSecondsKey, static_cast<float>( tuning.valid_pose_max_age_seconds ) ), 0.0, 2.0 );
	tuning.estimated_pose_time_max_age_seconds = ClampDouble(
		GetFloatSetting( kEstimatedPoseTimeMaxAgeSecondsKey, static_cast<float>( tuning.estimated_pose_time_max_age_seconds ) ), 0.0, 1.0 );
	tuning.pose_time_offset_min_seconds =
		ClampDouble( GetFloatSetting( kPoseTimeOffsetMinSecondsKey, static_cast<float>( tuning.pose_time_offset_min_seconds ) ), -1.0, 0.0 );
	tuning.pose_time_offset_max_seconds =
		ClampDouble( GetFloatSetting( kPoseTimeOffsetMaxSecondsKey, static_cast<float>( tuning.pose_time_offset_max_seconds ) ), 0.0, 1.0 );
	if ( tuning.position_filter_min_alpha > tuning.position_filter_max_alpha )
		std::swap( tuning.position_filter_min_alpha, tuning.position_filter_max_alpha );
	if ( tuning.rotation_filter_min_alpha > tuning.rotation_filter_max_alpha )
		std::swap( tuning.rotation_filter_min_alpha, tuning.rotation_filter_max_alpha );
	return tuning;
}
}

vr::EVRInitError UtkWifiDeviceProvider::Init( vr::IVRDriverContext *driver_context )
{
	VR_INIT_SERVER_DRIVER_CONTEXT( driver_context );

	const std::string bind_host = GetStringSetting( kUdpBindHostKey, "127.0.0.1" );
	const int32_t udp_port = GetIntSetting( kUdpPortKey, 5557 );
	const int32_t tracker_count_setting = GetIntSetting( kTrackerCountKey, 3 );
	const int32_t tracker_count = tracker_count_setting < 1 ? 1 : ( tracker_count_setting > 16 ? 16 : tracker_count_setting );
	const float stale_timeout_seconds = GetFloatSetting( kStaleTimeoutSecondsKey, 2.0f );
	const UtkWifiTrackerTuning tuning = LoadTrackerTuning();

	DriverLog(
		"utk_wifi_tracker: tuning prediction=%d smoothing=%d hysteresis=%d hold_last_valid=%d require_status2_recovery=%d pred_pos=%.3f pred_rot=%.3f hold=%.3f valid_frames=%u recovery_frames=%u invalid_frames=%u status4_motion=%d status4_eps=[%.3f mps, %.4f m] valid_max_age=%.3f estimated_max_age=%.3f offset=[%.3f, %.3f]",
		tuning.prediction_enabled ? 1 : 0,
		tuning.smoothing_enabled ? 1 : 0,
		tuning.status_hysteresis_enabled ? 1 : 0,
		tuning.hold_uses_last_raw_valid_pose ? 1 : 0,
		tuning.require_status2_for_recovery ? 1 : 0,
		tuning.position_prediction_max_seconds,
		tuning.rotation_prediction_max_seconds,
		tuning.hold_timeout_seconds,
		tuning.valid_enter_frames,
		tuning.recovery_enter_frames,
		tuning.invalid_enter_frames,
		tuning.status4_requires_motion ? 1 : 0,
		tuning.status4_motion_epsilon_mps,
		tuning.status4_position_epsilon_m,
		tuning.valid_pose_max_age_seconds,
		tuning.estimated_pose_time_max_age_seconds,
		tuning.pose_time_offset_min_seconds,
		tuning.pose_time_offset_max_seconds );

	for ( int32_t index = 0; index < tracker_count; ++index )
	{
		const uint16_t port = static_cast<uint16_t>( udp_port + index );
		auto receiver = std::make_unique<UdpPoseReceiver>();
		if ( !receiver->Start( bind_host, port ) )
		{
			DriverLog( "utk_wifi_tracker: failed to start UDP receiver on %s:%u", bind_host.c_str(), static_cast<unsigned>( port ) );
			return vr::VRInitError_Driver_Failed;
		}

		char serial[32] = {};
		std::snprintf( serial, sizeof( serial ), "UTK_WIFI_%04d", static_cast<int>( index + 1 ) );
		auto tracker = std::make_unique<UtkWifiTrackerDevice>( receiver.get(), stale_timeout_seconds, tuning, serial );
		if ( !vr::VRServerDriverHost()->TrackedDeviceAdded(
				 tracker->SerialNumber().c_str(), vr::TrackedDeviceClass_GenericTracker, tracker.get() ) )
		{
			DriverLog( "utk_wifi_tracker: TrackedDeviceAdded failed for %s", serial );
			return vr::VRInitError_Driver_Failed;
		}

		DriverLog( "utk_wifi_tracker: registered %s on UDP %s:%u", serial, bind_host.c_str(), static_cast<unsigned>( port ) );
		receivers_.push_back( std::move( receiver ) );
		trackers_.push_back( std::move( tracker ) );
	}

	return vr::VRInitError_None;
}

void UtkWifiDeviceProvider::Cleanup()
{
	trackers_.clear();
	for ( auto &receiver : receivers_ )
		receiver->Stop();
	receivers_.clear();
}

const char *const *UtkWifiDeviceProvider::GetInterfaceVersions()
{
	return vr::k_InterfaceVersions;
}

void UtkWifiDeviceProvider::RunFrame()
{
	vr::VREvent_t event{};
	while ( vr::VRServerDriverHost()->PollNextEvent( &event, sizeof( event ) ) )
	{
	}
}

bool UtkWifiDeviceProvider::ShouldBlockStandbyMode()
{
	return false;
}

void UtkWifiDeviceProvider::EnterStandby()
{
}

void UtkWifiDeviceProvider::LeaveStandby()
{
}
