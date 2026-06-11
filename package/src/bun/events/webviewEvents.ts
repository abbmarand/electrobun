import ElectrobunEvent from "./event";

type DetailData = { detail: string };
export type BrowserDownloadEventDetail = {
	id: string;
	downloadId?: string | number;
	filename?: string;
	path?: string;
	destinationPath?: string;
	url?: string;
	sourceUrl?: string;
	originalUrl?: string;
	mimeType?: string;
	totalBytes?: number;
	receivedBytes?: number;
	percentComplete?: number;
	progress?: number;
	canResume?: boolean;
	error?: string;
	errorMessage?: string;
	errorCode?: string | number;
	errorDomain?: string;
};
type DownloadData = { detail: BrowserDownloadEventDetail };
type NewWindowOpenSource =
	| "native-navigation"
	| "native-ui"
	| "preload-anchor"
	| "preload-spa"
	| "target-blank"
	| "window-open";

type NewWindowOpenData = {
	detail:
		| string
		| {
				source?: NewWindowOpenSource;
				url: string;
				isCmdClick: boolean;
				modifierFlags?: number;
				navigationType?: string | number;
				isUserGesture?: boolean;
				targetFrame?: string;
				button?: number;
				targetDisposition?: number;
				userGesture?: boolean;
		  };
};
export type BrowserPermissionType =
	| "camera"
	| "microphone"
	| "geolocation"
	| "notifications"
	| "midi"
	| "clipboardRead"
	| "clipboardWrite"
	| "screen"
	| "midiSysex"
	| "topLevelStorageAccess"
	| "storageAccess"
	| "diskQuota"
	| "localFonts"
	| "handTracking"
	| "identityProvider"
	| "idleDetection"
	| "multipleDownloads"
	| "keyboardLock"
	| "pointerLock"
	| "protectedMediaIdentifier"
	| "registerProtocolHandler"
	| "vrSession"
	| "webAppInstallation"
	| "windowManagement"
	| "fileSystemAccess"
	| "localNetwork"
	| "loopbackNetwork"
	| "arSession"
	| "sensors"
	| "localNetworkAccess"
	| "other";
export type BrowserPermissionPlatform = "macos" | "windows" | "linux";
export type BrowserPermissionRequestDetail = {
	requestId: string;
	webviewId: number;
	origin: string;
	pageUrl: string;
	frameUrl: string;
	permissionTypes: BrowserPermissionType[];
	platform: BrowserPermissionPlatform;
};
type PermissionRequestData = {
	detail: BrowserPermissionRequestDetail;
};
type PermissionDecidedData = {
	detail: {
		requestId: string;
		decision: "allowOnce" | "allow" | "block";
	};
};

export default {
	willNavigate: (data: DetailData) => new ElectrobunEvent<DetailData, {}>("will-navigate", data),
	didNavigate: (data: DetailData) => new ElectrobunEvent<DetailData, {}>("did-navigate", data),
	didNavigateInPage: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("did-navigate-in-page", data),
	didCommitNavigation: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("did-commit-navigation", data),
	domReady: (data: DetailData) => new ElectrobunEvent<DetailData, {}>("dom-ready", data),
	newWindowOpen: (data: NewWindowOpenData) =>
		new ElectrobunEvent<NewWindowOpenData, {}>("new-window-open", data),
	hostMessage: (data: DetailData) => new ElectrobunEvent<DetailData, {}>("host-message", data),
	downloadStarted: (data: DownloadData) =>
		new ElectrobunEvent<DownloadData, {}>("download-started", data),
	downloadProgress: (data: DownloadData) =>
		new ElectrobunEvent<DownloadData, {}>("download-progress", data),
	downloadCompleted: (data: DownloadData) =>
		new ElectrobunEvent<DownloadData, {}>("download-completed", data),
	downloadFailed: (data: DownloadData) =>
		new ElectrobunEvent<DownloadData, {}>("download-failed", data),
	downloadCanceled: (data: DownloadData) =>
		new ElectrobunEvent<DownloadData, {}>("download-canceled", data),
	pageTitleUpdated: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("page-title-updated", data),
	faviconUpdated: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("favicon-updated", data),
	permissionRequested: (data: PermissionRequestData) =>
		new ElectrobunEvent<PermissionRequestData, {}>("permission-requested", data),
	permissionDecided: (data: PermissionDecidedData) =>
		new ElectrobunEvent<PermissionDecidedData, {}>("permission-decided", data)
};
