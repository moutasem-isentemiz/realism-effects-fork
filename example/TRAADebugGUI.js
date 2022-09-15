﻿import { Pane } from "tweakpane"
import { defaultTRAAOptions } from "../src/TRAAEffect"

export class TRAADebugGUI {
	constructor(traaEffect, params = defaultTRAAOptions) {
		const pane = new Pane()
		this.pane = pane
		pane.containerElem_.style.userSelect = "none"
		pane.containerElem_.style.width = "380px"

		params = { ...defaultTRAAOptions, ...params }

		pane.on("change", ev => {
			const { presetKey } = ev

			traaEffect[presetKey] = ev.value
		})

		const temporalResolveFolder = pane.addFolder({ title: "Temporal Resolve", expanded: false })

		temporalResolveFolder.addInput(params, "blend", { min: 0, max: 1, step: 0.001 })
		temporalResolveFolder.addInput(params, "qualityScale", { min: 0.01, max: 1, step: 0.125 })
		temporalResolveFolder.addInput(params, "dilation")
	}
}