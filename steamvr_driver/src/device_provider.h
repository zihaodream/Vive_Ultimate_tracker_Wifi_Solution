#pragma once

#include "openvr_driver.h"
#include "tracker_device_driver.h"
#include "udp_pose_receiver.h"

#include <memory>
#include <vector>

class UtkWifiDeviceProvider : public vr::IServerTrackedDeviceProvider
{
public:
	vr::EVRInitError Init( vr::IVRDriverContext *driver_context ) override;
	void Cleanup() override;
	const char *const *GetInterfaceVersions() override;
	void RunFrame() override;
	bool ShouldBlockStandbyMode() override;
	void EnterStandby() override;
	void LeaveStandby() override;

private:
	std::vector<std::unique_ptr<UdpPoseReceiver>> receivers_;
	std::vector<std::unique_ptr<UtkWifiTrackerDevice>> trackers_;
};
