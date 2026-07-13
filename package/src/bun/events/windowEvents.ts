import ElectrobunEvent from "./event";

export type BrowserWindowIdData = { id: number };
export type BrowserWindowResizeData = {
	id: number;
	x: number;
	y: number;
	width: number;
	height: number;
};
export type BrowserWindowMoveData = { id: number; x: number; y: number };
export type BrowserWindowKeyData = {
	id: number;
	keyCode: number;
	modifiers: number;
	isRepeat: boolean;
};

export type BrowserWindowEventMap = {
	close: ElectrobunEvent<BrowserWindowIdData, Record<string, never>>;
	resize: ElectrobunEvent<BrowserWindowResizeData, Record<string, never>>;
	move: ElectrobunEvent<BrowserWindowMoveData, Record<string, never>>;
	focus: ElectrobunEvent<BrowserWindowIdData, Record<string, never>>;
	blur: ElectrobunEvent<BrowserWindowIdData, Record<string, never>>;
	keyDown: ElectrobunEvent<BrowserWindowKeyData, Record<string, never>>;
	keyUp: ElectrobunEvent<BrowserWindowKeyData, Record<string, never>>;
};

export default {
	close: (data: BrowserWindowIdData) =>
		new ElectrobunEvent<BrowserWindowIdData, Record<string, never>>("close", data),
	resize: (data: BrowserWindowResizeData) =>
		new ElectrobunEvent<BrowserWindowResizeData, Record<string, never>>("resize", data),
	move: (data: BrowserWindowMoveData) =>
		new ElectrobunEvent<BrowserWindowMoveData, Record<string, never>>("move", data),
	focus: (data: BrowserWindowIdData) =>
		new ElectrobunEvent<BrowserWindowIdData, Record<string, never>>("focus", data),
	blur: (data: BrowserWindowIdData) =>
		new ElectrobunEvent<BrowserWindowIdData, Record<string, never>>("blur", data),
	keyDown: (data: BrowserWindowKeyData) =>
		new ElectrobunEvent<BrowserWindowKeyData, Record<string, never>>("keyDown", data),
	keyUp: (data: BrowserWindowKeyData) =>
		new ElectrobunEvent<BrowserWindowKeyData, Record<string, never>>("keyUp", data)
};
