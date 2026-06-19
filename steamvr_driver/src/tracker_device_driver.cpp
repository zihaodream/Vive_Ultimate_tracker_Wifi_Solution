#include "tracker_device_driver.h"

#include "driverlog.h"

#include <cmath>
#include <cstring>
#include <utility>

namespace
{
constexpr double kTemporaryVisibilityYOffsetMeters = 0.0;
constexpr double kPositionCalibrationR[3][3] = {
	{ 1.0, 0.0, 0.0 },
	{ 0.0, 1.0, 0.0 },
	{ 0.0, 0.0, 1.0 },
};
constexpr double kPositionCalibrationT[3] = { 0.0, 0.0, 0.0 };

void NormalizeQuaternion( double *x, double *y, double *z, double *w )
{
	const double norm = std::sqrt( ( *x * *x ) + ( *y * *y ) + ( *z * *z ) + ( *w * *w ) );
	if ( norm < 0.000001 )
	{
		*x = 0.0;
		*y = 0.0;
		*z = 0.0;
		*w = 1.0;
		return;
	}
	*x /= norm;
	*y /= norm;
	*z /= norm;
	*w /= norm;
}

double ClampPredictionSeconds( double value, double max_seconds, double deadband_seconds )
{
	if ( value < deadband_seconds )
		return 0.0;
	if ( value > max_seconds )
		return max_seconds;
	return value;
}

double VectorLength( double x, double y, double z )
{
	return std::sqrt( ( x * x ) + ( y * y ) + ( z * z ) );
}

void ApplyAngularPrediction(
	double *x, double *y, double *z, double *w, double wx, double wy, double wz, double seconds, double max_angular_velocity )
{
	const double angular_speed = VectorLength( wx, wy, wz );
	if ( seconds <= 0.0 || angular_speed < 0.000001 || angular_speed > max_angular_velocity )
		return;

	const double angle = angular_speed * seconds;
	const double half_angle = angle * 0.5;
	const double scale = std::sin( half_angle ) / angular_speed;
	const double dx = wx * scale;
	const double dy = wy * scale;
	const double dz = wz * scale;
	const double dw = std::cos( half_angle );

	const double old_x = *x;
	const double old_y = *y;
	const double old_z = *z;
	const double old_w = *w;
	*x = ( old_w * dx ) + ( old_x * dw ) + ( old_y * dz ) - ( old_z * dy );
	*y = ( old_w * dy ) - ( old_x * dz ) + ( old_y * dw ) + ( old_z * dx );
	*z = ( old_w * dz ) + ( old_x * dy ) - ( old_y * dx ) + ( old_z * dw );
	*w = ( old_w * dw ) - ( old_x * dx ) - ( old_y * dy ) - ( old_z * dz );
	NormalizeQuaternion( x, y, z, w );
}

double AdaptiveAlpha( double magnitude, double min_alpha, double max_alpha, double scale )
{
	if ( scale <= 0.0 )
		return max_alpha;
	double t = magnitude / scale;
	if ( t < 0.0 )
		t = 0.0;
	if ( t > 1.0 )
		t = 1.0;
	return min_alpha + ( ( max_alpha - min_alpha ) * t );
}

void SlerpQuaternion( double ax, double ay, double az, double aw, double bx, double by, double bz, double bw, double alpha,
					  double *out_x, double *out_y, double *out_z, double *out_w )
{
	double dot = ( ax * bx ) + ( ay * by ) + ( az * bz ) + ( aw * bw );
	if ( dot < 0.0 )
	{
		bx = -bx;
		by = -by;
		bz = -bz;
		bw = -bw;
		dot = -dot;
	}

	if ( dot > 0.9995 )
	{
		*out_x = ax + alpha * ( bx - ax );
		*out_y = ay + alpha * ( by - ay );
		*out_z = az + alpha * ( bz - az );
		*out_w = aw + alpha * ( bw - aw );
		NormalizeQuaternion( out_x, out_y, out_z, out_w );
		return;
	}

	const double theta_0 = std::acos( dot );
	const double theta = theta_0 * alpha;
	const double sin_theta = std::sin( theta );
	const double sin_theta_0 = std::sin( theta_0 );
	const double s0 = std::cos( theta ) - dot * sin_theta / sin_theta_0;
	const double s1 = sin_theta / sin_theta_0;
	*out_x = ( s0 * ax ) + ( s1 * bx );
	*out_y = ( s0 * ay ) + ( s1 * by );
	*out_z = ( s0 * az ) + ( s1 * bz );
	*out_w = ( s0 * aw ) + ( s1 * bw );
	NormalizeQuaternion( out_x, out_y, out_z, out_w );
}

void ApplyQuaternionHandednessFix( double *x, double *y, double *z, double *w )
{
	// Apply a local 180-degree X-axis offset. This targets the observed
	// 180-degree difference on roll and yaw while preserving calibrated position.
	const double old_x = *x;
	const double old_y = *y;
	const double old_z = *z;
	const double old_w = *w;
	*x = old_w;
	*y = old_z;
	*z = -old_y;
	*w = -old_x;
}

void ApplyPositionCalibration( const double in[3], double out[3] )
{
	for ( int row = 0; row < 3; ++row )
	{
		out[row] = kPositionCalibrationT[row];
		for ( int col = 0; col < 3; ++col )
			out[row] += kPositionCalibrationR[row][col] * in[col];
	}
}
}

UtkWifiTrackerDevice::UtkWifiTrackerDevice(
	UdpPoseReceiver *receiver, double stale_timeout_seconds, UtkWifiTrackerTuning tuning, std::string serial_number )
	: receiver_( receiver ),
	  stale_timeout_seconds_( stale_timeout_seconds ),
	  tuning_( tuning ),
	  serial_number_( std::move( serial_number ) )
{
}

vr::EVRInitError UtkWifiTrackerDevice::Activate( uint32_t object_id )
{
	device_index_ = object_id;
	active_ = true;

	vr::PropertyContainerHandle_t container = vr::VRProperties()->TrackedDeviceToPropertyContainer( device_index_ );
	vr::VRProperties()->SetStringProperty( container, vr::Prop_TrackingSystemName_String, "utk_wifi_tracker" );
	vr::VRProperties()->SetStringProperty( container, vr::Prop_ActualTrackingSystemName_String, "utk_wifi_tracker" );
	vr::VRProperties()->SetStringProperty( container, vr::Prop_ModelNumber_String, "VIVE Ultimate Tracker WiFi Bridge" );
	vr::VRProperties()->SetStringProperty( container, vr::Prop_SerialNumber_String, serial_number_.c_str() );
	vr::VRProperties()->SetStringProperty( container, vr::Prop_RenderModelName_String, "generic_tracker" );
	vr::VRProperties()->SetStringProperty( container, vr::Prop_ControllerType_String, "utk_wifi_tracker" );
	vr::VRProperties()->SetStringProperty(
		container, vr::Prop_InputProfilePath_String, "{utk_wifi_tracker}\\input\\utk_wifi_tracker_profile.json" );
	vr::VRProperties()->SetStringProperty( container, vr::Prop_ResourceRoot_String, "utk_wifi_tracker" );
	vr::VRProperties()->SetBoolProperty( container, vr::Prop_DeviceProvidesBatteryStatus_Bool, true );
	vr::VRProperties()->SetFloatProperty( container, vr::Prop_DeviceBatteryPercentage_Float, 1.0f );
	vr::VRProperties()->SetBoolProperty( container, vr::Prop_DeviceCanPowerOff_Bool, true );
	vr::VRProperties()->SetBoolProperty( container, vr::Prop_Identifiable_Bool, true );
	vr::VRProperties()->SetBoolProperty( container, vr::Prop_DeviceIsWireless_Bool, true );

	pose_thread_ = std::thread( &UtkWifiTrackerDevice::PoseUpdateThread, this );
	DriverLog( "utk_wifi_tracker: activated %s as device %u", serial_number_.c_str(), object_id );
	return vr::VRInitError_None;
}

void UtkWifiTrackerDevice::Deactivate()
{
	if ( active_.exchange( false ) && pose_thread_.joinable() )
		pose_thread_.join();
	device_index_ = vr::k_unTrackedDeviceIndexInvalid;
}

void UtkWifiTrackerDevice::EnterStandby()
{
	DriverLog( "utk_wifi_tracker: standby" );
}

void *UtkWifiTrackerDevice::GetComponent( const char *component_name_and_version )
{
	( void )component_name_and_version;
	return nullptr;
}

void UtkWifiTrackerDevice::DebugRequest( const char *request, char *response_buffer, uint32_t response_buffer_size )
{
	( void )request;
	if ( response_buffer && response_buffer_size > 0 )
		response_buffer[0] = '\0';
}

vr::DriverPose_t UtkWifiTrackerDevice::GetPose()
{
	vr::DriverPose_t pose = {};
	pose.qWorldFromDriverRotation.w = 1.0;
	pose.qDriverFromHeadRotation.w = 1.0;
	pose.deviceIsConnected = true;

	const UtkWifiPose latest = receiver_ ? receiver_->Latest() : UtkWifiPose{};
	const bool raw_pose_valid = PoseIsFreshAndValid( latest );
	const bool recovery_accepts_pose =
		!tuning_.require_status2_for_recovery || tracking_valid_ || latest.pose_status == 2;
	const bool accepted_raw_pose_valid = raw_pose_valid && recovery_accepts_pose;
	const bool status4_lost = latest.pose_status == 4 && !raw_pose_valid;
	const bool pose_valid = UpdateTrackingHysteresis( latest, accepted_raw_pose_valid );
	const bool using_hold_pose = pose_valid && tracking_state_ == UtkWifiTrackingState::Hold && tuning_.hold_uses_last_raw_valid_pose
		&& has_last_raw_valid_pose_;
	const UtkWifiPose render_pose = using_hold_pose ? last_raw_valid_pose_ : latest;
	if ( !has_reported_pose_state_ || pose_valid != last_pose_valid_ || tracking_state_ != last_logged_tracking_state_ )
	{
		DriverLog(
			"utk_wifi_tracker: tracking_state=%s pose=%s raw=%s accepted_raw=%s hold_pose=%d seq=%u status=%d status4_lost=%d valid_count=%u invalid_count=%u xyz=(%.3f, %.3f, %.3f)",
			TrackingStateName(),
			pose_valid ? "valid" : "invalid",
			raw_pose_valid ? "valid" : "invalid",
			accepted_raw_pose_valid ? "valid" : "invalid",
			using_hold_pose ? 1 : 0,
			static_cast<unsigned>( latest.seq ),
			latest.pose_status,
			status4_lost ? 1 : 0,
			consecutive_valid_count_,
			consecutive_invalid_count_,
			latest.x,
			latest.y,
			latest.z );
		has_reported_pose_state_ = true;
		last_pose_valid_ = pose_valid;
		last_logged_tracking_state_ = tracking_state_;
	}

	if ( !pose_valid )
	{
		pose.poseIsValid = false;
		pose.result = vr::TrackingResult_Running_OutOfRange;
		return pose;
	}

	double qx = render_pose.qx;
	double qy = render_pose.qy;
	double qz = render_pose.qz;
	double qw = render_pose.qw;
	NormalizeQuaternion( &qx, &qy, &qz, &qw );

	const auto now = std::chrono::steady_clock::now();
	auto pose_time_at = render_pose.received_at;
	bool using_estimated_pose_time = false;
	if ( render_pose.estimated_pose_at != std::chrono::steady_clock::time_point::min() )
	{
		const double estimated_age_seconds = std::chrono::duration<double>( now - render_pose.estimated_pose_at ).count();
		const bool estimated_not_too_old = estimated_age_seconds <= tuning_.estimated_pose_time_max_age_seconds;
		const bool estimated_not_too_future = estimated_age_seconds >= -tuning_.pose_time_offset_max_seconds;
		if ( estimated_not_too_old && estimated_not_too_future )
		{
			pose_time_at = render_pose.estimated_pose_at;
			using_estimated_pose_time = true;
		}
	}
	const double pose_age_seconds = std::chrono::duration<double>( now - pose_time_at ).count();
	const double linear_prediction_seconds = tuning_.prediction_enabled
		? ClampPredictionSeconds( pose_age_seconds, tuning_.position_prediction_max_seconds, tuning_.prediction_deadband_seconds )
		: 0.0;
	const double angular_prediction_seconds = tuning_.prediction_enabled
		? ClampPredictionSeconds( pose_age_seconds, tuning_.rotation_prediction_max_seconds, tuning_.prediction_deadband_seconds )
		: 0.0;
	ApplyAngularPrediction(
		&qx, &qy, &qz, &qw, render_pose.wx, render_pose.wy, render_pose.wz, angular_prediction_seconds, tuning_.max_prediction_angular_velocity_radps );
	ApplyQuaternionHandednessFix( &qx, &qy, &qz, &qw );

	const double velocity_magnitude = VectorLength( render_pose.vx, render_pose.vy, render_pose.vz );
	const double angular_velocity_magnitude = VectorLength( render_pose.wx, render_pose.wy, render_pose.wz );
	double lifted_position[3] = {
		render_pose.x
			+ ( velocity_magnitude <= tuning_.max_prediction_velocity_mps ? render_pose.vx * linear_prediction_seconds : 0.0 ),
		render_pose.y + kTemporaryVisibilityYOffsetMeters
			+ ( velocity_magnitude <= tuning_.max_prediction_velocity_mps ? render_pose.vy * linear_prediction_seconds : 0.0 ),
		render_pose.z
			+ ( velocity_magnitude <= tuning_.max_prediction_velocity_mps ? render_pose.vz * linear_prediction_seconds : 0.0 ),
	};
	const uint64_t render_count = using_hold_pose ? filter_received_count_ : ( receiver_ ? receiver_->ReceivedCount() : 0 );
	ApplyPoseConditioner( render_count, render_pose, lifted_position, &qx, &qy, &qz, &qw );
	ApplyPositionCalibration( lifted_position, pose.vecPosition );
	pose.qRotation.x = qx;
	pose.qRotation.y = qy;
	pose.qRotation.z = qz;
	pose.qRotation.w = qw;
	pose.vecVelocity[0] = using_hold_pose ? 0.0 : render_pose.vx;
	pose.vecVelocity[1] = using_hold_pose ? 0.0 : render_pose.vy;
	pose.vecVelocity[2] = using_hold_pose ? 0.0 : render_pose.vz;
	pose.vecAngularVelocity[0] = using_hold_pose ? 0.0 : render_pose.wx;
	pose.vecAngularVelocity[1] = using_hold_pose ? 0.0 : render_pose.wy;
	pose.vecAngularVelocity[2] = using_hold_pose ? 0.0 : render_pose.wz;
	if ( pose_time_at != std::chrono::steady_clock::time_point::min() )
	{
		double pose_time_offset = std::chrono::duration<double>( pose_time_at - now ).count();
		if ( pose_time_offset < tuning_.pose_time_offset_min_seconds )
			pose_time_offset = tuning_.pose_time_offset_min_seconds;
		if ( pose_time_offset > tuning_.pose_time_offset_max_seconds )
			pose_time_offset = tuning_.pose_time_offset_max_seconds;
		pose.poseTimeOffset = pose_time_offset;
		if ( ++pose_offset_log_tick_ % 300 == 0 )
		{
			DriverLog(
				"utk_wifi_tracker: poseTimeOffset=%.4f source=%s seq=%u device_time=%u ticks=%llu",
				pose.poseTimeOffset,
				using_estimated_pose_time ? "estimated" : "received",
				static_cast<unsigned>( render_pose.seq ),
				static_cast<unsigned>( render_pose.device_time ),
				static_cast<unsigned long long>( render_pose.device_time_ticks ) );
		}
	}
	if ( ++pose_telemetry_log_tick_ % 300 == 0 )
	{
		DriverLog(
			"utk_wifi_tracker: telemetry tracking_state=%s hold_pose=%d seq=%u pose_age_ms=%.2f pred_pos_ms=%.2f pred_rot_ms=%.2f velocity=%.3f angular_velocity=%.3f smoothing=%d",
			TrackingStateName(),
			using_hold_pose ? 1 : 0,
			static_cast<unsigned>( render_pose.seq ),
			pose_age_seconds * 1000.0,
			linear_prediction_seconds * 1000.0,
			angular_prediction_seconds * 1000.0,
			velocity_magnitude,
			angular_velocity_magnitude,
			tuning_.smoothing_enabled ? 1 : 0 );
	}
	pose.poseIsValid = true;
	pose.result = vr::TrackingResult_Running_OK;
	return pose;
}

const std::string &UtkWifiTrackerDevice::SerialNumber() const
{
	return serial_number_;
}

void UtkWifiTrackerDevice::PoseUpdateThread()
{
	uint64_t inactive_tick = 0;
	uint64_t last_submitted_count = 0;
	while ( active_ )
	{
		const uint64_t received_count = receiver_ ? receiver_->ReceivedCount() : 0;
		const bool has_ever_received_pose = received_count > 0;
		const bool has_new_pose = received_count != last_submitted_count;
		const bool submit_inactive_heartbeat = !has_ever_received_pose && ( inactive_tick++ % 20 == 0 );
		const bool submit_pose_heartbeat = has_ever_received_pose && ( inactive_tick++ % 10 == 0 );
		if ( device_index_ != vr::k_unTrackedDeviceIndexInvalid
			 && ( has_new_pose || submit_pose_heartbeat || submit_inactive_heartbeat ) )
		{
			vr::VRServerDriverHost()->TrackedDevicePoseUpdated( device_index_, GetPose(), sizeof( vr::DriverPose_t ) );
			last_submitted_count = received_count;
		}
		std::this_thread::sleep_for( has_ever_received_pose ? std::chrono::milliseconds( 1 ) : std::chrono::milliseconds( 50 ) );
	}
}

bool UtkWifiTrackerDevice::PoseIsFreshAndValid( const UtkWifiPose &pose ) const
{
	if ( pose.received_at == std::chrono::steady_clock::time_point::min() )
		return false;
	const double age_seconds = std::chrono::duration<double>( std::chrono::steady_clock::now() - pose.received_at ).count();
	if ( age_seconds > stale_timeout_seconds_ )
		return false;
	if ( age_seconds > tuning_.valid_pose_max_age_seconds )
		return false;
	if ( pose.pose_status == 2 )
	{
		has_status4_previous_position_ = false;
		return true;
	}
	if ( pose.pose_status != 4 )
	{
		has_status4_previous_position_ = false;
		return false;
	}
	return !Status4LooksOpticalLost( pose );
}

bool UtkWifiTrackerDevice::Status4LooksOpticalLost( const UtkWifiPose &pose ) const
{
	if ( !tuning_.status4_requires_motion )
		return false;
	if ( pose.received_at == last_status4_received_at_ )
		return last_status4_lost_;

	const double velocity_magnitude = VectorLength( pose.vx, pose.vy, pose.vz );
	double position_delta = tuning_.status4_position_epsilon_m;
	if ( has_status4_previous_position_ )
	{
		position_delta = VectorLength(
			pose.x - status4_previous_position_[0], pose.y - status4_previous_position_[1], pose.z - status4_previous_position_[2] );
	}
	status4_previous_position_[0] = pose.x;
	status4_previous_position_[1] = pose.y;
	status4_previous_position_[2] = pose.z;
	has_status4_previous_position_ = true;
	last_status4_received_at_ = pose.received_at;

	last_status4_lost_ = velocity_magnitude <= tuning_.status4_motion_epsilon_mps && position_delta <= tuning_.status4_position_epsilon_m;
	return last_status4_lost_;
}

bool UtkWifiTrackerDevice::PoseIsFreshEnoughForHold( const UtkWifiPose &pose ) const
{
	( void )pose;
	if ( last_raw_valid_at_ == std::chrono::steady_clock::time_point::min() )
		return false;
	const double age_seconds = std::chrono::duration<double>( std::chrono::steady_clock::now() - last_raw_valid_at_ ).count();
	return age_seconds <= tuning_.hold_timeout_seconds;
}

bool UtkWifiTrackerDevice::UpdateTrackingHysteresis( const UtkWifiPose &pose, bool raw_pose_valid )
{
	if ( pose.received_at != std::chrono::steady_clock::time_point::min() )
	{
		const double age_seconds = std::chrono::duration<double>( std::chrono::steady_clock::now() - pose.received_at ).count();
		if ( age_seconds > tuning_.valid_pose_max_age_seconds )
		{
			consecutive_valid_count_ = 0;
			consecutive_invalid_count_ = tuning_.invalid_enter_frames;
			tracking_valid_ = false;
			tracking_state_ = UtkWifiTrackingState::Invalid;
			filter_initialized_ = false;
			return false;
		}
	}

	if ( !tuning_.status_hysteresis_enabled )
	{
		const bool was_tracking_valid = tracking_valid_;
		consecutive_valid_count_ = raw_pose_valid ? 1 : 0;
		consecutive_invalid_count_ = raw_pose_valid ? 0 : 1;
		tracking_valid_ = raw_pose_valid;
		tracking_state_ = raw_pose_valid ? UtkWifiTrackingState::Valid : UtkWifiTrackingState::Invalid;
		if ( raw_pose_valid )
		{
			has_had_valid_tracking_ = true;
			last_raw_valid_at_ = std::chrono::steady_clock::now();
			RememberRawValidPose( pose );
		}
		if ( !tracking_valid_ )
			filter_initialized_ = false;
		if ( !was_tracking_valid && tracking_valid_ )
			filter_initialized_ = false;
		return raw_pose_valid;
	}

	if ( raw_pose_valid )
	{
		const bool was_tracking_valid = tracking_valid_;
		last_raw_valid_at_ = std::chrono::steady_clock::now();
		RememberRawValidPose( pose );
		++consecutive_valid_count_;
		consecutive_invalid_count_ = 0;
		const uint32_t required_valid_frames = has_had_valid_tracking_ ? tuning_.recovery_enter_frames : tuning_.valid_enter_frames;
		if ( !tracking_valid_ && consecutive_valid_count_ >= required_valid_frames )
		{
			tracking_valid_ = true;
			has_had_valid_tracking_ = true;
			filter_initialized_ = false;
		}
		tracking_state_ = tracking_valid_ ? UtkWifiTrackingState::Valid : UtkWifiTrackingState::Recovering;
		if ( !was_tracking_valid && tracking_valid_ )
			filter_initialized_ = false;
		return tracking_valid_;
	}

	consecutive_valid_count_ = 0;
	if ( tracking_valid_ && PoseIsFreshEnoughForHold( pose ) )
	{
		tracking_state_ = UtkWifiTrackingState::Hold;
		return true;
	}

	++consecutive_invalid_count_;
	if ( consecutive_invalid_count_ >= tuning_.invalid_enter_frames )
	{
		tracking_valid_ = false;
		filter_initialized_ = false;
	}
	tracking_state_ = tracking_valid_ ? UtkWifiTrackingState::Hold : UtkWifiTrackingState::Invalid;
	return tracking_valid_;
}

const char *UtkWifiTrackerDevice::TrackingStateName() const
{
	switch ( tracking_state_ )
	{
	case UtkWifiTrackingState::Valid:
		return "valid";
	case UtkWifiTrackingState::Hold:
		return "hold";
	case UtkWifiTrackingState::Recovering:
		return "recovering";
	case UtkWifiTrackingState::Invalid:
	default:
		return "invalid";
	}
}

void UtkWifiTrackerDevice::RememberRawValidPose( const UtkWifiPose &pose )
{
	last_raw_valid_pose_ = pose;
	has_last_raw_valid_pose_ = true;
}

void UtkWifiTrackerDevice::ApplyPoseConditioner( uint64_t received_count, const UtkWifiPose &pose, double position[3], double *qx,
												 double *qy, double *qz, double *qw )
{
	if ( !position || !qx || !qy || !qz || !qw )
		return;

	if ( !tuning_.smoothing_enabled )
	{
		filter_initialized_ = false;
		return;
	}

	if ( !filter_initialized_ || received_count < filter_received_count_ )
	{
		filter_initialized_ = true;
		filter_received_count_ = received_count;
		filtered_position_[0] = position[0];
		filtered_position_[1] = position[1];
		filtered_position_[2] = position[2];
		filtered_qx_ = *qx;
		filtered_qy_ = *qy;
		filtered_qz_ = *qz;
		filtered_qw_ = *qw;
		return;
	}

	if ( received_count == filter_received_count_ )
	{
		position[0] = filtered_position_[0];
		position[1] = filtered_position_[1];
		position[2] = filtered_position_[2];
		*qx = filtered_qx_;
		*qy = filtered_qy_;
		*qz = filtered_qz_;
		*qw = filtered_qw_;
		return;
	}

	filter_received_count_ = received_count;
	const double velocity_magnitude = VectorLength( pose.vx, pose.vy, pose.vz );
	const double angular_velocity_magnitude = VectorLength( pose.wx, pose.wy, pose.wz );
	const double position_alpha = AdaptiveAlpha(
		velocity_magnitude, tuning_.position_filter_min_alpha, tuning_.position_filter_max_alpha, tuning_.position_filter_velocity_scale );
	const double rotation_alpha = AdaptiveAlpha(
		angular_velocity_magnitude, tuning_.rotation_filter_min_alpha, tuning_.rotation_filter_max_alpha, tuning_.rotation_filter_angular_scale );

	for ( int axis = 0; axis < 3; ++axis )
	{
		filtered_position_[axis] += ( position[axis] - filtered_position_[axis] ) * position_alpha;
		position[axis] = filtered_position_[axis];
	}

	SlerpQuaternion( filtered_qx_, filtered_qy_, filtered_qz_, filtered_qw_, *qx, *qy, *qz, *qw, rotation_alpha,
					&filtered_qx_, &filtered_qy_, &filtered_qz_, &filtered_qw_ );
	*qx = filtered_qx_;
	*qy = filtered_qy_;
	*qz = filtered_qz_;
	*qw = filtered_qw_;
}
