import ElectrobunEvent from "./event";

type DetailData = { detail: string };
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
	| "screen";
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

export default {
	willNavigate: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("will-navigate", data),
	didNavigate: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("did-navigate", data),
	didNavigateInPage: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("did-navigate-in-page", data),
	didCommitNavigation: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("did-commit-navigation", data),
	domReady: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("dom-ready", data),
	newWindowOpen: (data: NewWindowOpenData) =>
		new ElectrobunEvent<NewWindowOpenData, {}>("new-window-open", data),
	hostMessage: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("host-message", data),
	downloadStarted: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("download-started", data),
	downloadProgress: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("download-progress", data),
	downloadCompleted: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("download-completed", data),
	downloadFailed: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("download-failed", data),
	pageTitleUpdated: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("page-title-updated", data),
	faviconUpdated: (data: DetailData) =>
		new ElectrobunEvent<DetailData, {}>("favicon-updated", data),
	permissionRequested: (data: PermissionRequestData) =>
		new ElectrobunEvent<PermissionRequestData, {}>(
			"permission-requested",
			data,
		),
};
