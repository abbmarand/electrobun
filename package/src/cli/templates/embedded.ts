export interface Template {
	name: string;
	files: Record<string, string>;
}

export const templates: Record<string, Template> = {};

export function getTemplateNames(): string[] {
	return Object.keys(templates);
}

export function getTemplate(name: string): Template | undefined {
	return templates[name];
}
